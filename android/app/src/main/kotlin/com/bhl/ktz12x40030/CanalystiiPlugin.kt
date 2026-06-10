package com.bhl.ktz12x40030

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

class CanalystiiPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var usbManager: UsbManager? = null
    private var connection: UsbDeviceConnection? = null
    private var epOut: UsbEndpoint? = null
    private var epIn: UsbEndpoint? = null
    private var readThread: Thread? = null
    @Volatile private var isRunning = false

    companion object {
        const val VID = 0x04D8
        const val PID = 0x0053
        const val ACTION_USB_PERMISSION = "com.bhl.ktz12x40030.CANALYSTII_PERMISSION"
        const val COMMAND_INIT = 1
        const val COMMAND_START = 2
        const val BTR0_250K = 0x01
        const val BTR1_250K = 0x1C
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        methodChannel = MethodChannel(binding.binaryMessenger, "canalystii/methods")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "canalystii/frames")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stopAndClose()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDevices" -> result.success(listDevices())
            "connect" -> {
                val deviceId = call.argument<Int>("deviceId")
                    ?: return result.error("ARGS", "deviceId required", null)
                connectDevice(deviceId, result)
            }
            "disconnect" -> {
                stopAndClose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun listDevices(): List<Map<String, Any>> {
        return (usbManager?.deviceList?.values ?: emptyList<UsbDevice>())
            .filter { it.vendorId == VID && it.productId == PID }
            .map { mapOf("deviceId" to it.deviceId, "name" to (it.productName ?: "CANalyst-II")) }
    }

    private fun connectDevice(deviceId: Int, result: MethodChannel.Result) {
        val manager = usbManager ?: return result.error("USB", "No USB manager", null)
        val device = manager.deviceList.values.find { it.deviceId == deviceId }
            ?: return result.error("NOT_FOUND", "Device not found", null)

        if (manager.hasPermission(device)) {
            openAndInit(device, result)
        } else {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            else PendingIntent.FLAG_UPDATE_CURRENT

            val pi = PendingIntent.getBroadcast(context, 0, Intent(ACTION_USB_PERMISSION), flags)
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context, intent: Intent) {
                    if (intent.action != ACTION_USB_PERMISSION) return
                    ctx.unregisterReceiver(this)
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        openAndInit(device, result)
                    } else {
                        result.error("PERM_DENIED", "USB permission denied", null)
                    }
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, IntentFilter(ACTION_USB_PERMISSION), Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(receiver, IntentFilter(ACTION_USB_PERMISSION))
            }
            manager.requestPermission(device, pi)
        }
    }

    private fun openAndInit(device: UsbDevice, result: MethodChannel.Result) {
        stopAndClose()
        val manager = usbManager ?: return result.error("USB", "No USB manager", null)
        val conn = manager.openDevice(device) ?: return result.error("OPEN", "Cannot open device", null)

        // Find the CAN channel 0 endpoints across all interfaces
        // CANalyst-II: EP2 OUT (0x02) = commands, EP1 IN (0x81) = messages
        var out: UsbEndpoint? = null
        var inp: UsbEndpoint? = null
        for (ifIdx in 0 until device.interfaceCount) {
            val iface = device.getInterface(ifIdx)
            conn.claimInterface(iface, true)
            for (i in 0 until iface.endpointCount) {
                val ep = iface.getEndpoint(i)
                if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                when (ep.address) {
                    0x02 -> out = ep  // EP2 OUT – channel 0 commands
                    0x81 -> inp = ep  // EP1 IN  – channel 0 messages
                }
            }
        }
        if (out == null || inp == null) {
            conn.close()
            return result.error("ENDPOINTS", "Bulk endpoints not found", null)
        }

        connection = conn
        epOut = out
        epIn = inp

        conn.bulkTransfer(out, buildInitCmd(), 64, 1000)
        conn.bulkTransfer(out, buildStartCmd(), 64, 1000)

        isRunning = true
        readThread = Thread {
            val buf = ByteArray(64)
            while (isRunning) {
                val n = conn.bulkTransfer(inp, buf, 64, 100)
                if (n >= 1) parseBuffer(buf)
            }
        }.also { it.isDaemon = true; it.start() }

        result.success(true)
    }

    private fun stopAndClose() {
        isRunning = false
        readThread?.join(600)
        readThread = null
        try { connection?.close() } catch (_: Exception) {}
        connection = null; epOut = null; epIn = null
    }

    private fun buildInitCmd(): ByteArray {
        val b = ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(COMMAND_INIT)
        b.putInt(0x00)       // acc_code
        b.putInt(-1)         // acc_mask = 0xFFFFFFFF
        b.putInt(0x00)       // unknown0
        b.putInt(0x01)       // filter
        b.putInt(0x00)       // unknown1
        b.putInt(BTR0_250K)  // timing0
        b.putInt(BTR1_250K)  // timing1
        b.putInt(0x00)       // mode
        b.putInt(0x01)       // unknown2
        // remaining 24 bytes stay zero
        return b.array()
    }

    private fun buildStartCmd(): ByteArray {
        val b = ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(COMMAND_START)
        return b.array()
    }

    private fun parseBuffer(buf: ByteArray) {
        val count = buf[0].toInt() and 0xFF
        if (count < 1 || count > 3) return
        for (i in 0 until count) {
            val off = 1 + i * 21
            if (off + 21 > buf.size) break
            parseMessage(buf, off)
        }
    }

    private fun parseMessage(buf: ByteArray, off: Int) {
        val bb = ByteBuffer.wrap(buf, off, 21).order(ByteOrder.LITTLE_ENDIAN)
        val canId = bb.int
        bb.int       // timestamp
        bb.get()     // time_flag
        bb.get()     // send_type
        val remote = bb.get().toInt() != 0
        val extended = bb.get().toInt() != 0
        val dlc = bb.get().toInt() and 0xFF
        if (remote || dlc > 8) return
        val data = ByteArray(dlc).also { bb.get(it) }
        val frame = mapOf(
            "id" to canId,
            "extended" to extended,
            "data" to data.map { it.toInt() and 0xFF },
        )
        mainHandler.post { eventSink?.success(frame) }
    }
}
