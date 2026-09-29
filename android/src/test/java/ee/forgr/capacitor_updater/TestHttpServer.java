package ee.forgr.capacitor_updater;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Minimal HTTP/1.1 server for unit tests: answers every request with one fixed body. */
final class TestHttpServer implements AutoCloseable {

    final List<String> requestLines = new CopyOnWriteArrayList<>();
    private final ServerSocket socket;
    private final ExecutorService pool = Executors.newCachedThreadPool();
    private final byte[] body;

    TestHttpServer(final byte[] body) throws IOException {
        this.body = body;
        this.socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
        this.pool.execute(() -> {
            while (!this.socket.isClosed()) {
                try {
                    final Socket client = this.socket.accept();
                    this.pool.execute(() -> this.serve(client));
                } catch (IOException e) {
                    return;
                }
            }
        });
    }

    String url(final String path) {
        return "http://127.0.0.1:" + this.socket.getLocalPort() + path;
    }

    private static String readLine(final InputStream in) throws IOException {
        final ByteArrayOutputStream line = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1 && c != '\n') {
            if (c != '\r') {
                line.write(c);
            }
        }
        return line.toString(StandardCharsets.ISO_8859_1.name());
    }

    private void serve(final Socket client) {
        try (Socket s = client) {
            final InputStream in = s.getInputStream();
            this.requestLines.add(readLine(in));
            int length = 0;
            String line;
            while (!(line = readLine(in)).isEmpty()) {
                if (line.toLowerCase().startsWith("content-length:")) {
                    length = Integer.parseInt(line.substring(15).trim());
                }
            }
            for (int i = 0; i < length; i++) {
                in.read();
            }
            final OutputStream out = s.getOutputStream();
            out.write(
                ("HTTP/1.1 200 OK\r\nContent-Length: " + this.body.length + "\r\nConnection: close\r\n\r\n").getBytes(
                    StandardCharsets.ISO_8859_1
                )
            );
            out.write(this.body);
            out.flush();
        } catch (IOException ignored) {
            // client went away
        }
    }

    @Override
    public void close() throws IOException {
        this.socket.close();
        this.pool.shutdownNow();
    }
}
