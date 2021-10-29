# capacitor-updater

Download app update from url

WIP, the project need help to be working
Android:
- unzip downloaded file in background
- restart app

Apple:
- unzip downloaded file in background with `SSZipArchive`
- copy new file in public folder
- restart app

## Install

```bash
npm install capacitor-updater
npx cap sync
```

```
import { updateApp } from 'capacitor-updater'
updateApp('URL_TO_S3_OR ANY_PLACE')
```

## API

<docgen-index>

* [`updateApp(...)`](#updateapp)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### updateApp(...)

```typescript
updateApp(options: { url: string; }) => any
```

| Param         | Type                          |
| ------------- | ----------------------------- |
| **`options`** | <code>{ url: string; }</code> |

**Returns:** <code>any</code>

--------------------

</docgen-api>


### Inspiraton

- [cordova-plugin-ionic](https://github.com/ionic-team/cordova-plugin-ionic)
- [capacitor-codepush](https://github.dev/mapiacompany/capacitor-codepush)
