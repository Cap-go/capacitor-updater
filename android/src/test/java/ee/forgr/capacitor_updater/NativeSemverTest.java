package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class NativeSemverTest {

    @Test
    public void treatsOneZeroAsEqualToOneZeroZero() {
        assertEquals(0, new NativeSemver("1.0").compareTo(new NativeSemver("1.0.0")));
        assertTrue(new NativeSemver("1.0").equals(new NativeSemver("1.0.0")));
    }

    @Test
    public void releaseIsGreaterThanPrereleaseWithSameCore() {
        assertTrue(new NativeSemver("1.0.0").compareTo(new NativeSemver("1.0.0-beta.1")) > 0);
        assertTrue(new NativeSemver("2.0.0").compareTo(new NativeSemver("2.0.0-beta")) > 0);
    }

    @Test
    public void prereleaseOrderingIsDeterministic() {
        assertTrue(new NativeSemver("2.0.0-beta").compareTo(new NativeSemver("2.0.0-beta.1")) < 0);
        assertTrue(new NativeSemver("2.0.0-beta.1").compareTo(new NativeSemver("2.0.0-rc.1")) < 0);
    }

    @Test
    public void buildMetadataDoesNotAffectPrecedence() {
        assertEquals(0, new NativeSemver("2.0.0").compareTo(new NativeSemver("2.0.0+build.1")));
        assertEquals(0, new NativeSemver("2.0.0+build.1").compareTo(new NativeSemver("2.0.0+build.2")));
    }

    @Test
    public void parseOrDefaultFallsBackForEmptyVersion() {
        assertEquals("0.0.0", NativeSemver.parseOrDefault("", "0.0.0").toString());
        assertEquals("0.0.0", NativeSemver.parseOrDefault(null, "0.0.0").toString());
    }

    @Test
    public void betaDotTwoIsLessThanBetaDotTen() {
        assertTrue(new NativeSemver("1.0.0-beta.2").compareTo(new NativeSemver("1.0.0-beta.10")) < 0);
        assertTrue(new NativeSemver("1.0.0-beta.10").compareTo(new NativeSemver("1.0.0-beta.2")) > 0);
    }

    @Test
    public void numericPrereleaseIdentifierPrecedesNonNumeric() {
        assertTrue(new NativeSemver("1.0.0-1").compareTo(new NativeSemver("1.0.0-alpha")) < 0);
        assertTrue(new NativeSemver("1.0.0-alpha.1").compareTo(new NativeSemver("1.0.0-alpha.beta")) < 0);
    }

    @Test
    public void underscoreSeparatesNumericCoreComponents() {
        assertEquals(0, new NativeSemver("1.2_3").compareTo(new NativeSemver("1.2.3")));
        assertTrue(new NativeSemver("1.2_3").compareTo(new NativeSemver("1.2")) > 0);
    }

    @Test
    public void hashCodeMatchesEqualsForZeroPaddedVersions() {
        assertEquals(new NativeSemver("1.0").hashCode(), new NativeSemver("1.0.0").hashCode());
        assertEquals(new NativeSemver("1.0.0-beta").hashCode(), new NativeSemver("1.0-beta").hashCode());
    }
}
