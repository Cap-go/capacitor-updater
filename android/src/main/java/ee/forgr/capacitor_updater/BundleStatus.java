/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import java.util.HashMap;
import java.util.Map;

public enum BundleStatus {
    SUCCESS("success"),
    ERROR("error"),
    PENDING("pending"),
    DELETED("deleted"),
    DOWNLOADING("downloading");

    public final String label;

    private static final Map<String, BundleStatus> BY_LABEL = new HashMap<>();

    static {
        for (final BundleStatus e : values()) {
            BY_LABEL.put(e.label, e);
        }
    }

    BundleStatus(final String label) {
        this.label = label;
    }

    @Override
    public String toString() {
        return this.label;
    }

    public static BundleStatus fromString(final String status) {
        if (status == null || status.isEmpty()) {
            return BundleStatus.PENDING;
        }
        return BundleStatus.BY_LABEL.get(status);
    }
}
