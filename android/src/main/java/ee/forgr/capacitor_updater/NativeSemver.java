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

    public NativeSemver(final String version) {
        if (version == null || version.isEmpty()) {
            throw new IllegalArgumentException("Version must not be empty");
        }
        this.original = version;
        this.numericParts = parseNumericParts(version);
        if (numericParts.isEmpty()) {
            throw new IllegalArgumentException("Version has no numeric components: " + version);
        }
    }

    private static List<Long> parseNumericParts(final String version) {
        final List<Long> parts = new ArrayList<>();
        final String[] segments = version.split("[.\\-+_]");
        for (final String segment : segments) {
            if (segment.isEmpty()) {
                continue;
            }
            int end = 0;
            while (end < segment.length() && Character.isDigit(segment.charAt(end))) {
                end++;
            }
            if (end > 0) {
                parts.add(Long.parseLong(segment.substring(0, end)));
            }
        }
        return parts;
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
        return 0;
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
        return compareTo((NativeSemver) other) == 0 && Objects.equals(original, ((NativeSemver) other).original);
    }

    @Override
    public int hashCode() {
        return Objects.hash(original, numericParts);
    }
}
