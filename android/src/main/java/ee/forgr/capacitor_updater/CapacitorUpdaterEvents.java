package ee.forgr.capacitor_updater;

public interface CapacitorUpdaterEvents {
    /**
     * Notify listeners of download progress.
     * @param percent Current percentage as an integer (e.g.: N out of 100)
     */
    default void notifyDownload(final int percent) {
        return;
    }
}
