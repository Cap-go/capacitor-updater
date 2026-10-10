package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import android.util.Base64;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import javax.crypto.Cipher;
import okhttp3.Interceptor;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Before;
import org.junit.BeforeClass;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/** Signed bundle metadata (spec capgo-bundle-v1 / capgo-manifest-v1), builtinMinimum and httpsOnly gates. */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class BundleSignatureTest {

    private static KeyPair keyPair;
    private static String publicKeyPem;

    @BeforeClass
    public static void setUpClass() throws Exception {
        CryptoCipher.setLogger(new Logger("BundleSignatureTest", new Logger.Options(Logger.LogLevel.silent)));
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        keyPair = generator.generateKeyPair();
        publicKeyPem = toPkcs1Pem(keyPair);
    }

    @Before
    public void setUp() {
        DownloadService.setHttpsOnly(true);
    }

    @After
    public void tearDown() {
        DownloadService.setHttpsOnly(true);
        DownloadService.setAllowHttpsToHttpRedirect(false);
    }

    /** X.509 SubjectPublicKeyInfo -> PKCS#1 RSAPublicKey PEM (what the plugin config carries). */
    private static String toPkcs1Pem(KeyPair pair) {
        byte[] x509 = pair.getPublic().getEncoded();
        // SPKI for RSA-2048: 30 82 LL LL | 30 0d ...(15 bytes algId) | 03 82 LL LL 00 | <PKCS#1 bytes>
        int offset = 4 + 15 + 5;
        byte[] pkcs1 = new byte[x509.length - offset];
        System.arraycopy(x509, offset, pkcs1, 0, pkcs1.length);
        return "-----BEGIN RSA PUBLIC KEY-----\n" + Base64.encodeToString(pkcs1, Base64.DEFAULT) + "-----END RSA PUBLIC KEY-----";
    }

    private static String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes) {
            String hex = Integer.toHexString(0xff & b);
            if (hex.length() == 1) {
                sb.append('0');
            }
            sb.append(hex);
        }
        return sb.toString();
    }

    private static byte[] hexToBytes(String hex) {
        byte[] data = new byte[hex.length() / 2];
        for (int i = 0; i < hex.length(); i += 2) {
            data[i / 2] = (byte) ((Character.digit(hex.charAt(i), 16) << 4) + Character.digit(hex.charAt(i + 1), 16));
        }
        return data;
    }

    /** Node privateEncrypt(RSA_PKCS1_PADDING) == Cipher RSA/ECB/PKCS1Padding ENCRYPT_MODE with the private key. */
    private static String privateEncryptHex(byte[] plain) throws Exception {
        Cipher cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding");
        cipher.init(Cipher.ENCRYPT_MODE, keyPair.getPrivate());
        return bytesToHex(cipher.doFinal(plain));
    }

    private static String sign(String payload) throws Exception {
        return privateEncryptHex(MessageDigest.getInstance("SHA-256").digest(payload.getBytes(StandardCharsets.UTF_8)));
    }

    private static final class StatsCapturingUpdater extends CapgoUpdater {

        final List<String> stats = new ArrayList<>();

        StatsCapturingUpdater() {
            super(mock(Logger.class));
        }

        @Override
        public void sendStats(final String action, final String versionName) {
            this.stats.add(action + ":" + versionName);
        }
    }

    // --- payloads ---

    @Test
    public void bundlePayloadIsByteExact() {
        String checksum = "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855";
        String payload = CryptoCipher.buildBundleSignaturePayload("1.2.3-beta.1", checksum);
        assertEquals(
            "capgo-bundle-v1\nversion:1.2.3-beta.1\nchecksum:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n",
            payload
        );
    }

    @Test
    public void manifestPayloadSortsByUtf8BytesAndKeepsNonAscii() {
        List<CryptoCipher.ManifestSignatureEntry> entries = new ArrayList<>();
        entries.add(new CryptoCipher.ManifestSignatureEntry("index.html", "aa"));
        entries.add(new CryptoCipher.ManifestSignatureEntry("assets/été.js", "dd"));
        entries.add(new CryptoCipher.ManifestSignatureEntry("Assets/logo.png", "BB"));
        entries.add(new CryptoCipher.ManifestSignatureEntry("assets/app.js.br", "cc"));
        String payload = CryptoCipher.buildManifestSignaturePayload("1.2.3", entries);
        // Uppercase 'A' (0x41) sorts before lowercase, and 'é' (0xC3 0xA9) sorts after every ASCII name.
        assertEquals(
            "capgo-manifest-v1\nversion:1.2.3\nAssets/logo.png:bb\nassets/app.js.br:cc\nassets/été.js:dd\nindex.html:aa\n",
            payload
        );
        byte[] bytes = payload.getBytes(StandardCharsets.UTF_8);
        assertEquals(payload.length() + 2, bytes.length); // "été" has two two-byte UTF-8 chars
    }

    @Test
    public void sha256HexMatchesMessageDigest() throws Exception {
        String input = "capgo-bundle-v1\nversion:é\n";
        String expected = bytesToHex(MessageDigest.getInstance("SHA-256").digest(input.getBytes(StandardCharsets.UTF_8)));
        assertEquals(expected, CryptoCipher.sha256Hex(input));
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", CryptoCipher.sha256Hex(""));
    }

    // --- verifySignature round trip ---

    @Test
    public void verifySignatureRoundTrip() throws Exception {
        String payload = CryptoCipher.buildBundleSignaturePayload("1.0.0", "ab".repeat(32));
        String signature = sign(payload);
        assertEquals(512, signature.length());
        assertTrue(CryptoCipher.verifySignature(signature, payload, publicKeyPem));
        assertTrue(CryptoCipher.verifySignature(signature.toUpperCase(), payload, publicKeyPem));
        assertFalse(CryptoCipher.verifySignature(signature, payload + "x", publicKeyPem));
        assertFalse(CryptoCipher.verifySignature(signature.substring(2), payload, publicKeyPem));
        assertFalse(CryptoCipher.verifySignature(signature + "00", payload, publicKeyPem));
        assertFalse(CryptoCipher.verifySignature("zz" + signature.substring(2), payload, publicKeyPem));
        assertFalse(CryptoCipher.verifySignature("", payload, publicKeyPem));
        assertFalse(CryptoCipher.verifySignature(null, payload, publicKeyPem));
        assertFalse(CryptoCipher.verifySignature(signature, payload, ""));
    }

    @Test
    public void verifySignatureRejectsRecoveredBytesOfOtherLength() throws Exception {
        String payload = CryptoCipher.buildBundleSignaturePayload("1.0.0", "ab".repeat(32));
        // Signed a 31-byte truncated digest: recovers fine but is not the sha256 of the payload.
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(payload.getBytes(StandardCharsets.UTF_8));
        byte[] truncated = new byte[31];
        System.arraycopy(digest, 0, truncated, 0, 31);
        assertFalse(CryptoCipher.verifySignature(privateEncryptHex(truncated), payload, publicKeyPem));
    }

    // --- CapgoUpdater gates ---

    @Test
    public void bundleGateAcceptsValidAndRejectsTampered() throws Exception {
        String plainChecksum = "cd".repeat(32);
        String encryptedChecksum = privateEncryptHex(hexToBytes(plainChecksum));
        String signature = sign(CryptoCipher.buildBundleSignaturePayload("2.0.0", plainChecksum));

        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.publicKey = publicKeyPem;
        updater.verifyBundleSignature("2.0.0", encryptedChecksum, signature);
        assertTrue(updater.stats.isEmpty());

        IOException error = assertThrows(IOException.class, () -> updater.verifyBundleSignature("2.0.1", encryptedChecksum, signature));
        assertEquals("Bundle signature verification failed", error.getMessage());
        assertEquals(List.of("signature_fail:2.0.1"), updater.stats);

        // Checksum swapped for another signed-looking value: payload no longer matches.
        String otherChecksum = privateEncryptHex(hexToBytes("ef".repeat(32)));
        assertThrows(IOException.class, () -> updater.verifyBundleSignature("2.0.0", otherChecksum, signature));
        // Plain (unencrypted) checksum with a public key is itself rejected by decryptChecksum.
        assertThrows(IOException.class, () -> updater.verifyBundleSignature("2.0.0", plainChecksum, signature));
    }

    @Test
    public void bundleGateSkipsWithoutPublicKeyOrSignature() throws Exception {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.verifyBundleSignature("2.0.0", "not-even-hex", "garbage");
        updater.publicKey = publicKeyPem;
        updater.verifyBundleSignature("2.0.0", privateEncryptHex(hexToBytes("cd".repeat(32))), "");
        updater.verifyBundleSignature("2.0.0", privateEncryptHex(hexToBytes("cd".repeat(32))), null);
        assertTrue(updater.stats.isEmpty());
    }

    @Test
    public void manifestGateBindsTheWholeSet() throws Exception {
        String[][] files = { { "index.html", "aa".repeat(32) }, { "assets/été.js", "bb".repeat(32) }, { "Assets/x.png", "cc".repeat(32) } };
        List<CryptoCipher.ManifestSignatureEntry> entries = new ArrayList<>();
        JSONArray manifest = new JSONArray();
        for (String[] file : files) {
            entries.add(new CryptoCipher.ManifestSignatureEntry(file[0], file[1]));
            manifest.put(
                new JSONObject()
                    .put("file_name", file[0])
                    .put("file_hash", privateEncryptHex(hexToBytes(file[1])))
                    .put("download_url", "https://cdn.example/" + file[0])
            );
        }
        String signature = sign(CryptoCipher.buildManifestSignaturePayload("3.0.0", entries));

        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.publicKey = publicKeyPem;
        updater.verifyManifestSignature("3.0.0", manifest, signature);
        assertTrue(updater.stats.isEmpty());

        // Dropped entry
        JSONArray dropped = new JSONArray();
        dropped.put(manifest.getJSONObject(0));
        dropped.put(manifest.getJSONObject(1));
        assertThrows(IOException.class, () -> updater.verifyManifestSignature("3.0.0", dropped, signature));
        // Added entry
        JSONArray added = new JSONArray();
        for (int i = 0; i < manifest.length(); i++) {
            added.put(manifest.getJSONObject(i));
        }
        added.put(
            new JSONObject()
                .put("file_name", "evil.js")
                .put("file_hash", privateEncryptHex(hexToBytes("dd".repeat(32))))
                .put("download_url", "https://cdn.example/evil.js")
        );
        assertThrows(IOException.class, () -> updater.verifyManifestSignature("3.0.0", added, signature));
        // Renamed entry
        JSONArray renamed = new JSONArray();
        for (int i = 0; i < manifest.length(); i++) {
            JSONObject copy = new JSONObject(manifest.getJSONObject(i).toString());
            if (i == 0) {
                copy.put("file_name", "index2.html");
            }
            renamed.put(copy);
        }
        assertThrows(IOException.class, () -> updater.verifyManifestSignature("3.0.0", renamed, signature));
        // Wrong version
        assertThrows(IOException.class, () -> updater.verifyManifestSignature("3.0.1", manifest, signature));
        assertEquals(4, updater.stats.size());
        assertTrue(updater.stats.stream().allMatch((s) -> s.startsWith("signature_fail:")));
    }

    @Test
    public void manifestGateWithoutSignatureOnlyWarns() throws Exception {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.publicKey = publicKeyPem;
        updater.verifyManifestSignature("3.0.0", new JSONArray(), "");
        assertTrue(updater.stats.isEmpty());
    }

    // --- builtinMinimum ---

    @Test
    public void builtinMinimumAcceptsEqualOrHigher() throws Exception {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.versionBuild = "1.2.3";
        updater.requireVersionNotBelowBuiltin("1.2.3");
        updater.requireVersionNotBelowBuiltin("1.2.4");
        updater.requireVersionNotBelowBuiltin("2.0.0-beta.1");
        // Prerelease at the native version is not a rollback: only major.minor.patch are compared.
        updater.requireVersionNotBelowBuiltin("1.2.3-beta.1");
        // Fourth components and build metadata are ignored.
        updater.versionBuild = "1.2.3.4";
        updater.requireVersionNotBelowBuiltin("1.2.3.3");
        updater.requireVersionNotBelowBuiltin("1.2.3+build.42");
        assertTrue(updater.stats.isEmpty());
        updater.versionBuild = "2.0.0";
        assertThrows(IOException.class, () -> updater.requireVersionNotBelowBuiltin("1.9.9+build.42"));
    }

    @Test
    public void builtinMinimumRejectsLower() {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.versionBuild = "1.2.3";
        IOException error = assertThrows(IOException.class, () -> updater.requireVersionNotBelowBuiltin("1.2.2"));
        assertEquals("Bundle version 1.2.2 is below native version 1.2.3 (builtinMinimum)", error.getMessage());
        assertThrows(IOException.class, () -> updater.requireVersionNotBelowBuiltin("0.9.0"));
        assertEquals(List.of("version_below_native:1.2.2", "version_below_native:0.9.0"), updater.stats);
    }

    @Test
    public void builtinMinimumSkipsUnparseableAndDisabled() throws Exception {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        updater.versionBuild = "1.2.3";
        updater.requireVersionNotBelowBuiltin("builtin");
        updater.requireVersionNotBelowBuiltin("");
        updater.requireVersionNotBelowBuiltin(null);
        updater.versionBuild = "";
        updater.requireVersionNotBelowBuiltin("0.0.1");
        updater.versionBuild = "dev-build";
        updater.requireVersionNotBelowBuiltin("0.0.1");
        updater.versionBuild = "1.2.3";
        updater.builtinMinimum = false;
        updater.requireVersionNotBelowBuiltin("0.0.1");
        assertTrue(updater.stats.isEmpty());
    }

    // --- httpsOnly ---

    @Test
    public void updaterRejectsHttpUrlsBeforeNetwork() throws Exception {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        IOException error = assertThrows(IOException.class, () -> updater.requireHttpsUrls("http://example.com/a.zip", null));
        assertEquals("httpsOnly is enabled and http://example.com/a.zip is not https", error.getMessage());
        updater.requireHttpsUrls("https://example.com/a.zip", null);
        JSONArray manifest = new JSONArray().put(new JSONObject().put("file_name", "a").put("download_url", "http://cdn.example/a"));
        assertThrows(IOException.class, () -> updater.requireHttpsUrls("https://example.com/a.zip", manifest));
        updater.httpsOnly = false;
        updater.requireHttpsUrls("http://example.com/a.zip", manifest);
        assertTrue(updater.stats.isEmpty());
    }

    private static Response response(String requestUrl, int code, String location) {
        Response.Builder builder = new Response.Builder()
            .request(new Request.Builder().url(requestUrl).build())
            .protocol(Protocol.HTTP_1_1)
            .code(code)
            .message("status")
            .body(ResponseBody.create(new byte[0], null));
        if (location != null) {
            builder.header("Location", location);
        }
        return builder.build();
    }

    private static Response runNetworkInterceptor(Response upstream) throws IOException {
        Interceptor.Chain chain = mock(Interceptor.Chain.class);
        when(chain.request()).thenReturn(upstream.request());
        when(chain.proceed(any(Request.class))).thenReturn(upstream);
        Interceptor interceptor = DownloadService.sharedClient.networkInterceptors().get(0);
        return interceptor.intercept(chain);
    }

    private static Response runAppInterceptor(Response upstream) throws IOException {
        Interceptor.Chain chain = mock(Interceptor.Chain.class);
        when(chain.request()).thenReturn(upstream.request());
        when(chain.proceed(any(Request.class))).thenReturn(upstream);
        Interceptor interceptor = DownloadService.sharedClient.interceptors().get(0);
        return interceptor.intercept(chain);
    }

    @Test
    public void interceptorsRejectHttpWhenHttpsOnly() throws IOException {
        Response plain = response("http://api.capgo.app/updates", 200, null);
        IOException network = assertThrows(IOException.class, () -> runNetworkInterceptor(plain));
        assertEquals("httpsOnly is enabled and http://api.capgo.app/updates is not https", network.getMessage());
        IOException app = assertThrows(IOException.class, () -> runAppInterceptor(plain));
        assertEquals("httpsOnly is enabled and http://api.capgo.app/updates is not https", app.getMessage());

        Response secure = response("https://api.capgo.app/updates", 200, null);
        assertEquals(secure, runNetworkInterceptor(secure));

        DownloadService.setHttpsOnly(false);
        assertEquals(plain, runNetworkInterceptor(plain));
    }

    @Test
    public void httpsOnlyOverridesAllowHttpsToHttpRedirect() throws IOException {
        DownloadService.setAllowHttpsToHttpRedirect(true);
        Response downgrade = response("https://api.capgo.app/a", 302, "http://example.com/bundle.zip");
        IOException error = assertThrows(IOException.class, () -> runNetworkInterceptor(downgrade));
        assertEquals("httpsOnly is enabled and http://example.com/bundle.zip is not https", error.getMessage());
    }

    @Test
    public void downloadEntryPointsRejectHttpBeforeAnyWork() {
        StatsCapturingUpdater updater = new StatsCapturingUpdater();
        IOException error = assertThrows(IOException.class, () -> updater.download("http://example.com/a.zip", "1.0.0", "", "abc"));
        assertEquals("httpsOnly is enabled and http://example.com/a.zip is not https", error.getMessage());
        assertThrows(IOException.class, () -> updater.downloadManifest("http://example.com/a.zip", "1.0.0", "", "abc", null));
    }
}
