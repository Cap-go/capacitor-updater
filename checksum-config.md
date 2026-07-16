# Checksum Failure Prevention & Recovery Guide

## What is a Checksum Failure?

A checksum failure occurs when the Capacitor Updater plugin detects that a downloaded bundle's integrity doesn't match the expected hash. This prevents corrupted or tampered files from being installed.

## Common Causes

1. **Network issues** - Incomplete downloads due to poor connectivity
2. **Server issues** - Corrupted files on CDN/storage
3. **Encryption issues** - Problems with public key decryption
4. **Cache corruption** - Local cache files become corrupted
5. **Wrong checksums** - Server providing incorrect checksum values

## Immediate Solutions

### Option 1: Reset to Working Bundle

```javascript
import { CapacitorUpdater } from '@capgo/capacitor-updater'

// Reset to last successful bundle
await CapacitorUpdater.reset({ toLastSuccessful: true })

// Or reset to factory/builtin bundle
await CapacitorUpdater.reset({ toLastSuccessful: false })
```

### Option 2: Manual Cleanup

```javascript
// Check bundle status
const bundles = await CapacitorUpdater.list()
const current = await CapacitorUpdater.getCurrent()

// Delete corrupted bundles
for (const bundle of bundles.bundles) {
  if (bundle.status === 'error' && bundle.id !== current.bundle.id) {
    await CapacitorUpdater.delete({ id: bundle.id })
  }
}
```

### Option 3: Use the Fix Script

```javascript
// Import the fix script
import { fixChecksumFailure, checkBundleHealth } from './fix-checksum-failure.js'

// Check current status
await checkBundleHealth()

// Apply automatic fix
await fixChecksumFailure()
```

## Server-side Solutions

### Re-upload Bundle with Correct Checksum

```bash
# Using the fix script
node CLI/fix-checksum-server.ts your-app-id --bundle ./dist --channel production

# With checksum bypass (if needed)
node CLI/fix-checksum-server.ts your-app-id --ignore-checksum --force
```

### Using Standard CLI

```bash
# Re-upload with force flag
npx @capgo/cli bundle upload --force

# Upload with checksum bypass
npx @capgo/cli bundle upload --ignore-checksum-check
```

## Prevention Strategies

### 1. Capacitor Config

```typescript
// capacitor.config.ts
export default {
  plugins: {
    CapacitorUpdater: {
      // Auto-delete failed bundles
      autoDeleteFailed: true,
      
      // Auto-delete previous bundles after successful update
      autoDeletePrevious: true,
      
      // Delete obsolete bundles on native version upgrade
      deleteBundleOnNativeUpgrade: true,
      
      // Timeout for bundle downloads (ms)
      timeout: 60000
    }
  }
}
```

### 2. Error Handling in App

```javascript
// Add error handling for update failures
CapacitorUpdater.addListener('downloadFailed', (info) => {
  console.error('Download failed:', info)
  if (info.error?.includes('checksum')) {
    // Trigger automatic recovery
    fixChecksumFailure()
  }
})

CapacitorUpdater.addListener('bundleError', (info) => {
  console.error('Bundle error:', info)
  // Reset to working version
  CapacitorUpdater.reset({ toLastSuccessful: true })
})
```

### 3. Network Resilience

```javascript
// Implement retry logic
async function downloadWithRetry(maxRetries = 3) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      const result = await CapacitorUpdater.download({ url: updateUrl })
      return result
    } catch (error) {
      if (error.message?.includes('checksum') && i < maxRetries - 1) {
        console.warn(`Checksum failed, retry ${i + 1}/${maxRetries}`)
        await new Promise(resolve => setTimeout(resolve, 1000 * (i + 1)))
        continue
      }
      throw error
    }
  }
}
```

## Debugging Checksum Issues

### 1. Enable Debug Logging

```typescript
// capacitor.config.ts
export default {
  plugins: {
    CapacitorUpdater: {
      // Enable verbose logging
      logLevel: 'debug'
    }
  }
}
```

### 2. Check Bundle Health

```javascript
// Log detailed bundle information
const health = await checkBundleHealth()
console.log('Bundle health report:', health)
```

### 3. Verify Server Checksums

```bash
# Check if server-side checksums are correct
curl -I "https://your-cdn.com/bundle.zip"
# Look for X-Checksum-Sha256 header

# Calculate local checksum
openssl dgst -sha256 -binary bundle.zip | openssl base64
```

## Emergency Recovery

If all else fails, implement an emergency reset mechanism:

```javascript
// Emergency reset function
async function emergencyReset() {
  try {
    // Clear all stored preferences
    await CapacitorUpdater.reset({ toLastSuccessful: false })
    
    // Clear app cache if possible
    if ('serviceWorker' in navigator) {
      const registrations = await navigator.serviceWorker.getRegistrations()
      await Promise.all(registrations.map(reg => reg.unregister()))
    }
    
    // Force app reload
    window.location.reload()
    
  } catch (error) {
    console.error('Emergency reset failed:', error)
    // Show user manual restart instruction
    alert('Please manually restart the app')
  }
}
```

## Summary

1. **Immediate**: Use `reset()` or `delete()` corrupted bundles
2. **Server-side**: Re-upload bundles with correct checksums  
3. **Prevention**: Configure auto-cleanup and error handling
4. **Emergency**: Implement fallback reset mechanisms

The key is to have multiple recovery layers so users can always get back to a working state.





