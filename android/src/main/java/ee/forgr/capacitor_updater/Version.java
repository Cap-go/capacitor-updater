/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Parsing and comparison logic ported from version-compare 1.5.0
 * (https://github.com/G00fY2/version-compare), Copyright G00fY2,
 * licensed under the Apache License, Version 2.0
 * (https://www.apache.org/licenses/LICENSE-2.0).
 */

package ee.forgr.capacitor_updater;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Lenient version parser and comparator.
 *
 * <p>Behavior-compatible port of {@code io.github.g00fy2:versioncompare:1.5.0} (Apache-2.0), kept in-repo so the
 * plugin does not ship an extra third-party dependency. Parsing never throws for non-null input that starts with a
 * digit; unparsable input (null or not starting with a digit) yields an empty version equal to {@code 0}.
 *
 * <p>Pre-release suffix ordering: {@code snapshot < pre-alpha < alpha < beta < rc < stable}, with an optional number
 * right after the qualifier ({@code 1.0.0-rc2 > 1.0.0-rc1}).
 */
public class Version implements Comparable<Version> {

    enum ReleaseType {
        SNAPSHOT,
        PRE_ALPHA,
        ALPHA,
        BETA,
        RC,
        STABLE
    }

    private static final String SNAPSHOT_STRING = "snapshot";
    private static final String PRE_STRING = "pre";
    private static final String ALPHA_STRING = "alpha";
    private static final String BETA_STRING = "beta";
    private static final String RC_STRING = "rc";

    @Nullable
    private final String originalString;

    private final List<Long> subversionNumbers = new ArrayList<>();
    private final List<Long> trimmedSubversionNumbers = new ArrayList<>();
    private final String suffix;
    private final ReleaseType releaseType;
    private final long preReleaseVersion;

    public Version(@Nullable String versionString) {
        originalString = versionString;
        if (originalString != null && startsNumeric(originalString)) {
            String[] versionTokens = originalString.replaceAll("\\s", "").split("\\.");
            boolean suffixFound = false;
            StringBuilder suffixSb = null;

            for (String versionToken : versionTokens) {
                if (suffixFound) {
                    suffixSb.append(".");
                    suffixSb.append(versionToken);
                } else if (isNumeric(versionToken)) {
                    subversionNumbers.add(safeParseLong(versionToken));
                } else {
                    for (int i = 0; i < versionToken.length(); i++) {
                        if (!Character.isDigit(versionToken.charAt(i))) {
                            suffixSb = new StringBuilder();
                            if (i > 0) {
                                subversionNumbers.add(safeParseLong(versionToken.substring(0, i)));
                                suffixSb.append(versionToken.substring(i));
                            } else {
                                suffixSb.append(versionToken);
                            }
                            suffixFound = true;
                            break;
                        }
                    }
                }
            }
            suffix = (suffixSb != null) ? suffixSb.toString() : "";
            trimmedSubversionNumbers.addAll(subversionNumbers);
            while (!trimmedSubversionNumbers.isEmpty() && trimmedSubversionNumbers.get(trimmedSubversionNumbers.size() - 1) == 0L) {
                trimmedSubversionNumbers.remove(trimmedSubversionNumbers.size() - 1);
            }
        } else {
            suffix = "";
        }
        releaseType = qualifierToReleaseType(suffix);
        preReleaseVersion = preReleaseVersion(suffix, releaseType);
    }

    public long getMajor() {
        return trimmedSubversionNumbers.size() > 0 ? trimmedSubversionNumbers.get(0) : 0L;
    }

    public long getMinor() {
        return trimmedSubversionNumbers.size() > 1 ? trimmedSubversionNumbers.get(1) : 0L;
    }

    public long getPatch() {
        return trimmedSubversionNumbers.size() > 2 ? trimmedSubversionNumbers.get(2) : 0L;
    }

    @NonNull
    public List<Long> getSubversionNumbers() {
        return subversionNumbers;
    }

    @NonNull
    public String getSuffix() {
        return suffix;
    }

    @Nullable
    public String getOriginalString() {
        return originalString;
    }

    public boolean isHigherThan(String otherVersion) {
        return isHigherThan(new Version(otherVersion));
    }

    public boolean isHigherThan(Version otherVersion) {
        return compareTo(otherVersion) > 0;
    }

    public boolean isLowerThan(String otherVersion) {
        return isLowerThan(new Version(otherVersion));
    }

    public boolean isLowerThan(Version otherVersion) {
        return compareTo(otherVersion) < 0;
    }

    public boolean isEqual(String otherVersion) {
        return isEqual(new Version(otherVersion));
    }

    public boolean isEqual(Version otherVersion) {
        return compareTo(otherVersion) == 0;
    }

    public boolean isAtLeast(String otherVersion) {
        return isAtLeast(new Version(otherVersion));
    }

    public boolean isAtLeast(Version otherVersion) {
        return compareTo(otherVersion) >= 0;
    }

    public boolean isAtLeast(String otherVersion, boolean ignoreSuffix) {
        return isAtLeast(new Version(otherVersion), ignoreSuffix);
    }

    public boolean isAtLeast(Version otherVersion, boolean ignoreSuffix) {
        return compareTo(otherVersion, ignoreSuffix) >= 0;
    }

    @Override
    public final int compareTo(@NonNull Version version) {
        return compareTo(version, false);
    }

    private int compareTo(@NonNull Version version, boolean ignoreSuffix) {
        int versionNumberResult = compareSubversionNumbers(trimmedSubversionNumbers, version.trimmedSubversionNumbers);
        if (versionNumberResult != 0 || ignoreSuffix) {
            return versionNumberResult;
        }
        int releaseTypeResult = releaseType.compareTo(version.releaseType);
        if (releaseTypeResult != 0) {
            return releaseTypeResult;
        }
        return Long.compare(preReleaseVersion, version.preReleaseVersion);
    }

    @Override
    public final boolean equals(Object o) {
        return o instanceof Version && isEqual((Version) o);
    }

    @Override
    public final int hashCode() {
        int result = trimmedSubversionNumbers.hashCode();
        result = 31 * result + releaseType.hashCode();
        result = 31 * result + (int) (preReleaseVersion ^ (preReleaseVersion >>> 32));
        return result;
    }

    @NonNull
    @Override
    public String toString() {
        return String.valueOf(originalString);
    }

    // helpers

    private static int compareSubversionNumbers(@NonNull final List<Long> versionNumbersA, @NonNull final List<Long> versionNumbersB) {
        final int numbersSizeA = versionNumbersA.size();
        final int numbersSizeB = versionNumbersB.size();
        final int maxSize = Math.max(numbersSizeA, numbersSizeB);

        for (int i = 0; i < maxSize; i++) {
            final long a = i < numbersSizeA ? versionNumbersA.get(i) : 0L;
            final long b = i < numbersSizeB ? versionNumbersB.get(i) : 0L;
            if (a > b) {
                return 1;
            } else if (a < b) {
                return -1;
            }
        }
        return 0;
    }

    static ReleaseType qualifierToReleaseType(@NonNull String suffix) {
        if (suffix.length() > 0) {
            suffix = suffix.toLowerCase(Locale.ROOT);
            if (suffix.contains(RC_STRING)) return ReleaseType.RC;
            if (suffix.contains(BETA_STRING)) return ReleaseType.BETA;
            if (suffix.contains(ALPHA_STRING)) {
                if (suffix.substring(0, suffix.indexOf(ALPHA_STRING)).contains(PRE_STRING)) {
                    return ReleaseType.PRE_ALPHA;
                }
                return ReleaseType.ALPHA;
            }
            if (suffix.contains(SNAPSHOT_STRING)) return ReleaseType.SNAPSHOT;
        }
        return ReleaseType.STABLE;
    }

    private static long preReleaseVersion(@NonNull final String suffix, final ReleaseType releaseType) {
        if (releaseType == ReleaseType.STABLE || releaseType == ReleaseType.SNAPSHOT) return 0;

        final int startIndex = indexOfQualifier(suffix, releaseType);
        if (startIndex < suffix.length()) {
            final int maxStartIndex = Math.min(startIndex + 2, suffix.length());
            if (containsNumeric(suffix.substring(startIndex, maxStartIndex))) {
                final StringBuilder versionNumber = new StringBuilder();
                for (int i = startIndex; i < suffix.length(); i++) {
                    final char c = suffix.charAt(i);
                    if (Character.isDigit(c)) {
                        versionNumber.append(c);
                    } else if (i != startIndex) {
                        break;
                    }
                }
                return safeParseLong(versionNumber.toString());
            }
        }
        return 0;
    }

    private static int indexOfQualifier(@NonNull String suffix, final ReleaseType releaseType) {
        suffix = suffix.toLowerCase(Locale.ROOT);
        switch (releaseType) {
            case RC:
                return suffix.indexOf(RC_STRING) + RC_STRING.length();
            case BETA:
                return suffix.indexOf(BETA_STRING) + BETA_STRING.length();
            case ALPHA:
            case PRE_ALPHA:
                return suffix.indexOf(ALPHA_STRING) + ALPHA_STRING.length();
            default:
                return 0;
        }
    }

    private static boolean startsNumeric(@NonNull String str) {
        str = str.trim();
        return str.length() > 0 && Character.isDigit(str.charAt(0));
    }

    private static long safeParseLong(@NonNull String numbers) {
        if (numbers.length() > 19) {
            numbers = numbers.substring(0, 19);
        }
        return Long.parseLong(numbers);
    }

    private static boolean isNumeric(@NonNull final CharSequence cs) {
        final int sz = cs.length();
        if (sz > 0) {
            for (int i = 0; i < sz; i++) {
                if (!Character.isDigit(cs.charAt(i))) {
                    return false;
                }
            }
            return true;
        }
        return false;
    }

    private static boolean containsNumeric(@NonNull final CharSequence cs) {
        final int sz = cs.length();
        for (int i = 0; i < sz; i++) {
            if (Character.isDigit(cs.charAt(i))) {
                return true;
            }
        }
        return false;
    }
}
