/**
 * Fix for "Checksum Failed" errors in Capacitor Updater
 * 
 * This script provides multiple solutions to recover from checksum failures:
 * 1. Reset to working bundle
 * 2. Delete corrupted bundles 
 * 3. List and analyze bundle status
 */

import { CapacitorUpdater } from '@capgo/capacitor-updater'

async function fixChecksumFailure() {
  try {
    // Solution 1: Reset to last successful bundle
    console.log('Attempting to reset to last successful bundle...')
    await CapacitorUpdater.reset({ toLastSuccessful: true })
    console.log('Reset successful - app will reload')
    
  } catch (resetError) {
    console.warn('Reset to last successful failed, trying builtin reset:', resetError)
    
    try {
      // Solution 2: Reset to builtin bundle (factory reset)
      console.log('Resetting to builtin bundle...')
      await CapacitorUpdater.reset({ toLastSuccessful: false })
      console.log('Reset to builtin successful - app will reload')
      
    } catch (builtinResetError) {
      console.error('Builtin reset failed:', builtinResetError)
      
      // Solution 3: Manual cleanup of corrupted bundles
      await manualCleanup()
    }
  }
}

async function manualCleanup() {
  try {
    console.log('Starting manual cleanup of corrupted bundles...')
    
    // List all bundles to identify corrupted ones
    const bundleList = await CapacitorUpdater.list()
    console.log('Available bundles:', bundleList.bundles)
    
    // Get current bundle info
    const current = await CapacitorUpdater.getCurrent()
    console.log('Current bundle:', current.bundle)
    
    // Delete bundles with error status
    for (const bundle of bundleList.bundles) {
      if (bundle.status === 'error' && bundle.id !== current.bundle.id && bundle.id !== 'builtin') {
        console.log(`Deleting corrupted bundle: ${bundle.id}`)
        try {
          await CapacitorUpdater.delete({ id: bundle.id })
          console.log(`Successfully deleted bundle: ${bundle.id}`)
        } catch (deleteError) {
          console.error(`Failed to delete bundle ${bundle.id}:`, deleteError)
        }
      }
    }
    
    console.log('Manual cleanup completed')
    
  } catch (error) {
    console.error('Manual cleanup failed:', error)
  }
}

// Utility function to check bundle health
async function checkBundleHealth() {
  try {
    const bundleList = await CapacitorUpdater.list()
    const current = await CapacitorUpdater.getCurrent()
    
    console.log('=== Bundle Health Report ===')
    console.log('Current bundle:', current.bundle)
    console.log('Native version:', current.native)
    console.log('\nAll bundles:')
    
    bundleList.bundles.forEach(bundle => {
      console.log(`- ID: ${bundle.id}`)
      console.log(`  Version: ${bundle.version}`)
      console.log(`  Status: ${bundle.status}`)
      console.log(`  Downloaded: ${bundle.downloaded}`)
      console.log(`  Checksum: ${bundle.checksum || 'N/A'}`)
      console.log('  ---')
    })
    
    return bundleList
    
  } catch (error) {
    console.error('Failed to check bundle health:', error)
    return null
  }
}

// Export functions for use in app
export {
  fixChecksumFailure,
  manualCleanup,
  checkBundleHealth
}

// Auto-run if called directly
if (typeof window !== 'undefined') {
  // In browser/app context
  window.fixChecksumFailure = fixChecksumFailure
  window.checkBundleHealth = checkBundleHealth
  console.log('Checksum fix functions available globally')
}





