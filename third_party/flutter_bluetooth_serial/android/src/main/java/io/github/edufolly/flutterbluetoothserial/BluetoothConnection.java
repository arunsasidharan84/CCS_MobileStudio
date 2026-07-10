package io.github.edufolly.flutterbluetoothserial;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.UUID;
import java.util.Arrays;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothSocket;

import android.util.Log;

/// Universal Bluetooth serial connection class (for Java)
public abstract class BluetoothConnection
{
    private static final String TAG = "BluetoothConnection";
    protected static final UUID DEFAULT_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB");

    protected BluetoothAdapter bluetoothAdapter;

    protected ConnectionThread connectionThread = null;

    public boolean isConnected() {
        return connectionThread != null && connectionThread.requestedClosing != true;
    }



    public BluetoothConnection(BluetoothAdapter bluetoothAdapter) {
        this.bluetoothAdapter = bluetoothAdapter;
    }



    /// Connects to given device by hardware address with fallback
    public void connect(String address, UUID uuid) throws IOException {
        if (isConnected()) {
            throw new IOException("already connected");
        }

        BluetoothDevice device = bluetoothAdapter.getRemoteDevice(address);
        if (device == null) {
            throw new IOException("device not found");
        }

        // Cancel discovery before connecting
        bluetoothAdapter.cancelDiscovery();

        BluetoothSocket socket = null;
        IOException lastException = null;

        // 1. Try insecure RFCOMM connection first (crucial for no-PIN SPP modules like xAMP / EpiDome)
        try {
            socket = device.createInsecureRfcommSocketToServiceRecord(uuid);
            if (socket != null) {
                socket.connect();
            }
        } catch (IOException e) {
            lastException = e;
            Log.w(TAG, "Insecure RFCOMM socket connect failed: " + e.getMessage() + ". Trying secure RFCOMM...");
            try { if (socket != null) socket.close(); } catch (Exception ignored) {}
            socket = null;
        }

        // 2. Try secure RFCOMM connection
        if (socket == null) {
            try {
                socket = device.createRfcommSocketToServiceRecord(uuid);
                if (socket != null) {
                    socket.connect();
                }
            } catch (IOException e) {
                lastException = e;
                Log.w(TAG, "Secure RFCOMM socket connect failed: " + e.getMessage() + ". Trying reflection RFCOMM channel 1...");
                try { if (socket != null) socket.close(); } catch (Exception ignored) {}
                socket = null;
            }
        }

        // 3. Try reflection createRfcommSocket (channel 1 fallback)
        if (socket == null) {
            try {
                socket = (BluetoothSocket) device.getClass().getMethod("createRfcommSocket", new Class<?>[] {int.class}).invoke(device, 1);
                if (socket != null) {
                    socket.connect();
                }
            } catch (Exception e) {
                Log.e(TAG, "Reflection RFCOMM socket connect failed: " + e.getMessage());
                try { if (socket != null) socket.close(); } catch (Exception ignored) {}
                throw new IOException("Failed to connect via insecure, secure, and reflection RFCOMM: " + (lastException != null ? lastException.getMessage() : e.getMessage()), e);
            }
        }

        if (socket == null) {
            throw new IOException("socket connection not established");
        }

        connectionThread = new ConnectionThread(socket);
        connectionThread.start();
    }
    /// Connects to given device by hardware address (default UUID used)
    public void connect(String address) throws IOException {
        connect(address, DEFAULT_UUID);
    }
    
    /// Disconnects current session (ignore if not connected)
    public void disconnect() {
        if (isConnected()) {
            connectionThread.cancel();
            connectionThread = null;
        }
    }

    /// Writes to connected remote device 
    public void write(byte[] data) throws IOException {
        if (!isConnected()) {
            throw new IOException("not connected");
        }

        connectionThread.write(data);
    }

    /// Callback for reading data.
    protected abstract void onRead(byte[] data);

    /// Callback for disconnection.
    protected abstract void onDisconnected(boolean byRemote);

    /// Thread to handle connection I/O
    private class ConnectionThread extends Thread  {
        private final BluetoothSocket socket;
        private final InputStream input;
        private final OutputStream output;
        private boolean requestedClosing = false;
        
        ConnectionThread(BluetoothSocket socket) {
            this.socket = socket;
            InputStream tmpIn = null;
            OutputStream tmpOut = null;

            try {
                tmpIn = socket.getInputStream();
                tmpOut = socket.getOutputStream();
            } catch (IOException e) {
                e.printStackTrace();
            }

            this.input = tmpIn;
            this.output = tmpOut;
        }

        /// Thread main code
        public void run() {
            byte[] buffer = new byte[1024];
            int bytes;

            while (!requestedClosing) {
                try {
                    bytes = input.read(buffer);

                    onRead(Arrays.copyOf(buffer, bytes));
                } catch (IOException e) {
                    // `input.read` throws when closed by remote device
                    break;
                }
            }

            // Make sure output stream is closed
            if (output != null) {
                try {
                    output.close();
                }
                catch (Exception e) {}
            }

            // Make sure input stream is closed
            if (input != null) {
                try {
                    input.close();
                }
                catch (Exception e) {}
            }

            // Callback on disconnected, with information which side is closing
            onDisconnected(!requestedClosing);

            // Just prevent unnecessary `cancel`ing
            requestedClosing = true;
        }

        /// Writes to output stream
        public void write(byte[] bytes) {
            try {
                output.write(bytes);
            } catch (IOException e) {
                e.printStackTrace();
            }
        }

        /// Stops the thread, disconnects
        public void cancel() {
            if (requestedClosing) {
                return;
            }
            requestedClosing = true;

            // Flush output buffers befoce closing
            try {
                output.flush();
            }
            catch (Exception e) {}

            // Close the connection socket
            if (socket != null) {
                try {
                    // Might be useful (see https://stackoverflow.com/a/22769260/4880243)
                    Thread.sleep(111);

                    socket.close();
                }
                catch (Exception e) {}
            }
        }
    }
}
