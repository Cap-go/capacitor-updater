package ee.forgr.capacitor_updater;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * Lightweight semver-style comparator for native app version strings.
 * Replaces the third-party versioncompare dependency for delay-update checks.
 */
public final class NativeSemver implements Comparable<NativeSemver> {

    private static final BigInteger UINT64_MAX = new BigInteger("18446744073709551615");

    private final String original;
    private final List<BigInteger> numericParts;
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
            final String prereleasePart = working.substring(dashIdx + 1);
            return new CoreParts(working.substring(0, dashIdx), prereleasePart.isEmpty() ? null : prereleasePart);
        }
        return new CoreParts(working, null);
    }

    private static List<BigInteger> parseNumericParts(final String core) {
        final List<BigInteger> parts = new ArrayList<>();
        for (final String segment : core.split("[._]")) {
            if (segment.isEmpty()) {
                continue;
            }
            int end = 0;
            while (end < segment.length() && isAsciiDigit(segment.charAt(end))) {
                end++;
            }
            if (end > 0) {
                parts.add(parseNumericComponent(segment.substring(0, end)));
            }
        }
        return parts;
    }

    private static BigInteger parseNumericComponent(final String digits) {
        if (digits.length() > 20) {
            return UINT64_MAX;
        }
        try {
            final BigInteger value = new BigInteger(digits);
            return value.compareTo(UINT64_MAX) > 0 ? UINT64_MAX : value;
        } catch (final NumberFormatException ignored) {
            return UINT64_MAX;
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
            final BigInteger left = i < numericParts.size() ? numericParts.get(i) : BigInteger.ZERO;
            final BigInteger right = i < other.numericParts.size() ? other.numericParts.get(i) : BigInteger.ZERO;
            final int cmp = left.compareTo(right);
            if (cmp != 0) {
                return cmp;
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
        return comparePrerelease(prerelease, other.prerelease);
    }

    private static int comparePrerelease(final String left, final String right) {
        final String[] leftIds = left.split("\\.");
        final String[] rightIds = right.split("\\.");
        final int max = Math.max(leftIds.length, rightIds.length);
        for (int i = 0; i < max; i++) {
            if (i >= leftIds.length) {
                return -1;
            }
            if (i >= rightIds.length) {
                return 1;
            }
            final int cmp = comparePrereleaseIdentifier(leftIds[i], rightIds[i]);
            if (cmp != 0) {
                return cmp;
            }
        }
        return 0;
    }

    private static int comparePrereleaseIdentifier(final String left, final String right) {
        final boolean leftNumeric = isNumericIdentifier(left);
        final boolean rightNumeric = isNumericIdentifier(right);
        if (leftNumeric && rightNumeric) {
            // SemVer: compare numeric identifiers by digit magnitude (length, then lexical).
            final int lengthCmp = Integer.compare(stripLeadingZeros(left).length(), stripLeadingZeros(right).length());
            if (lengthCmp != 0) {
                return lengthCmp;
            }
            final int digitCmp = stripLeadingZeros(left).compareTo(stripLeadingZeros(right));
            if (digitCmp != 0) {
                return digitCmp;
            }
            return 0;
        }
        if (leftNumeric) {
            return -1;
        }
        if (rightNumeric) {
            return 1;
        }
        return left.compareTo(right);
    }

    /** SemVer numeric identifiers are ASCII digits only (`0`–`9`), not Unicode Nd/No. */
    private static boolean isAsciiDigit(final char c) {
        return c >= '0' && c <= '9';
    }

    private static boolean isNumericIdentifier(final String value) {
        if (value.isEmpty()) {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            if (!isAsciiDigit(value.charAt(i))) {
                return false;
            }
        }
        return true;
    }

    private static String stripLeadingZeros(final String digits) {
        int i = 0;
        while (i < digits.length() - 1 && digits.charAt(i) == '0') {
            i++;
        }
        return digits.substring(i);
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
        final List<BigInteger> normalized = new ArrayList<>(numericParts);
        while (normalized.size() > 1 && normalized.get(normalized.size() - 1).equals(BigInteger.ZERO)) {
            normalized.remove(normalized.size() - 1);
        }
        return Objects.hash(normalized, prerelease);
    }
}
