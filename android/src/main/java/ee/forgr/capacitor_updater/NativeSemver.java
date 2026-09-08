package ee.forgr.capacitor_updater;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * Lightweight semver-style comparator for native app version strings.
 * Replaces the third-party versioncompare dependency for delay-update checks.
 */
public final class NativeSemver implements Comparable<NativeSemver> {

    private final String original;
    private final List<Long> numericParts;
    private final String prerelease;

    public static NativeSemver parseOrDefault(final String version, final String fallback) {
        try {
            if (version == null || version.isEmpty()) {
                return new NativeSemver(fallback);
            }
            return new NativeSemver(version);
        } catch (final IllegalArgumentException ignored) {
            return new NativeSemver(fallback);
        }
    }

    public NativeSemver(final String version) {
        if (version == null || version.isEmpty()) {
            throw new IllegalArgumentException("Version must not be empty");
        }
        this.original = version;
        final CoreParts core = splitCoreAndPrerelease(version);
        this.numericParts = parseNumericParts(core.core);
        this.prerelease = core.prerelease;
        if (numericParts.isEmpty()) {
            throw new IllegalArgumentException("Version has no numeric components: " + version);
        }
    }

    private static final class CoreParts {

        private final String core;
        private final String prerelease;

        private CoreParts(final String core, final String prerelease) {
            this.core = core;
            this.prerelease = prerelease;
        }
    }

    private static CoreParts splitCoreAndPrerelease(final String version) {
        String working = version;
        final int plusIdx = working.indexOf('+');
        if (plusIdx >= 0) {
            working = working.substring(0, plusIdx);
        }
        final int dashIdx = working.indexOf('-');
        if (dashIdx >= 0) {
            return new CoreParts(working.substring(0, dashIdx), working.substring(dashIdx + 1));
        }
        return new CoreParts(working, null);
    }

    private static List<Long> parseNumericParts(final String core) {
        final List<Long> parts = new ArrayList<>();
        for (final String segment : core.split("\\.")) {
            if (segment.isEmpty()) {
                continue;
            }
            int end = 0;
            while (end < segment.length() && Character.isDigit(segment.charAt(end))) {
                end++;
            }
            if (end > 0) {
                parts.add(parseNumericComponent(segment.substring(0, end)));
            }
        }
        return parts;
    }

    private static long parseNumericComponent(final String digits) {
        if (digits.length() > 19) {
            return Long.MAX_VALUE;
        }
        try {
            return Long.parseLong(digits);
        } catch (final NumberFormatException ignored) {
            return Long.MAX_VALUE;
        }
    }

    public boolean isAtLeast(final String version) {
        return compareTo(new NativeSemver(version)) >= 0;
    }

    public boolean isLowerThan(final NativeSemver other) {
        return compareTo(other) < 0;
    }

    public boolean isEqual(final NativeSemver other) {
        return compareTo(other) == 0;
    }

    @Override
    public int compareTo(final NativeSemver other) {
        final int max = Math.max(numericParts.size(), other.numericParts.size());
        for (int i = 0; i < max; i++) {
            final long left = i < numericParts.size() ? numericParts.get(i) : 0L;
            final long right = i < other.numericParts.size() ? other.numericParts.get(i) : 0L;
            if (left < right) {
                return -1;
            }
            if (left > right) {
                return 1;
            }
        }
        if (prerelease == null && other.prerelease == null) {
            return 0;
        }
        if (prerelease == null) {
            return 1;
        }
        if (other.prerelease == null) {
            return -1;
        }
        return prerelease.compareTo(other.prerelease);
    }

    @Override
    public String toString() {
        return original;
    }

    @Override
    public boolean equals(final Object other) {
        if (this == other) {
            return true;
        }
        if (!(other instanceof NativeSemver)) {
            return false;
        }
        return compareTo((NativeSemver) other) == 0;
    }

    @Override
    public int hashCode() {
        return Objects.hash(numericParts, prerelease);
    }
}
