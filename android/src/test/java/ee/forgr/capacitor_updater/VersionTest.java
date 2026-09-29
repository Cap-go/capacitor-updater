package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.Collections;
import org.junit.Test;

public class VersionTest {

    @Test
    public void parsesNumericParts() {
        Version v = new Version("1.2.3");
        assertEquals(1, v.getMajor());
        assertEquals(2, v.getMinor());
        assertEquals(3, v.getPatch());
        assertEquals("", v.getSuffix());
        assertEquals("1.2.3", v.getOriginalString());
        assertEquals("1.2.3", v.toString());
        assertEquals(Arrays.asList(1L, 2L, 3L), v.getSubversionNumbers());
    }

    @Test
    public void trailingZerosAreIgnoredForComparison() {
        assertTrue(new Version("1").isEqual("1.0.0"));
        assertTrue(new Version("1.0").isEqual(new Version("1.0.0.0")));
        assertEquals(new Version("1.0"), new Version("1.0.0"));
        assertEquals(new Version("1.0").hashCode(), new Version("1.0.0").hashCode());
        assertEquals(Arrays.asList(1L, 0L, 0L), new Version("1.0.0").getSubversionNumbers());
    }

    @Test
    public void comparesNumerically() {
        assertTrue(new Version("1.10.0").isHigherThan("1.9.9"));
        assertTrue(new Version("1.0.0").isLowerThan("1.0.1"));
        assertTrue(new Version("2.0.0").isAtLeast("2.0.0"));
        assertFalse(new Version("1.9").isAtLeast("1.10"));
        assertTrue(new Version("1.2.3.4").isHigherThan("1.2.3"));
    }

    @Test
    public void splitsSuffixFromLastNumericPart() {
        Version v = new Version("1.2.3-beta.4");
        assertEquals(Arrays.asList(1L, 2L, 3L), v.getSubversionNumbers());
        assertEquals("-beta.4", v.getSuffix());

        Version leading = new Version("1.2.rc1");
        assertEquals(Arrays.asList(1L, 2L), leading.getSubversionNumbers());
        assertEquals("rc1", leading.getSuffix());
    }

    @Test
    public void ordersPreReleaseQualifiers() {
        String[] ordered = {
            "1.0.0-snapshot",
            "1.0.0-pre-alpha",
            "1.0.0-alpha",
            "1.0.0-alpha2",
            "1.0.0-beta",
            "1.0.0-rc1",
            "1.0.0-rc.2",
            "1.0.0"
        };
        for (int i = 0; i < ordered.length - 1; i++) {
            assertTrue(ordered[i] + " < " + ordered[i + 1], new Version(ordered[i]).isLowerThan(ordered[i + 1]));
        }
        assertTrue(new Version("1.0.0-RC1").isEqual("1.0.0-rc1"));
        assertTrue(new Version("1.0.0-custom").isEqual("1.0.0"));
    }

    @Test
    public void ignoreSuffixComparesNumbersOnly() {
        assertTrue(new Version("1.0.0-alpha").isAtLeast("1.0.0", true));
        assertFalse(new Version("1.0.0-alpha").isAtLeast("1.0.0"));
    }

    @Test
    public void invalidInputIsZeroAndNeverThrows() {
        Version nullVersion = new Version(null);
        assertNull(nullVersion.getOriginalString());
        assertEquals("null", nullVersion.toString());
        assertEquals(Collections.emptyList(), nullVersion.getSubversionNumbers());
        assertTrue(nullVersion.isEqual("0"));

        Version text = new Version("v1.2.3");
        assertEquals(0, text.getMajor());
        assertEquals("", text.getSuffix());
        assertTrue(text.isEqual(""));
        assertTrue(new Version("1.2.3").isHigherThan("abc"));
    }

    @Test
    public void whitespaceAndOverlongNumbers() {
        assertTrue(new Version(" 1 . 2 ").isEqual("1.2"));
        assertEquals(1234567890123456789L, new Version("12345678901234567890").getMajor());
    }
}
