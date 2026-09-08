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
}
