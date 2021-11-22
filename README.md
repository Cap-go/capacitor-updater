# capacitor-updater

Download app update from url

WIP, the project need help to be working

Android:
- unzip downloaded file in background
- restart app

Apple:
- persist downloaded version between app launches
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

* [`download(...)`](#download)
* [`set(...)`](#set)
* [`delete(...)`](#delete)
* [`list()`](#list)
* [`load()`](#load)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### download(...)

```typescript
download(options: { url: string; }) => any
```

download new version from url

| Param         | Type                          |
| ------------- | ----------------------------- |
| **`options`** | <code>{ url: string; }</code> |

**Returns:** <code>any</code>

--------------------


### set(...)

```typescript
set(options: { version: string; }) => any
```

set version as current version

| Param         | Type                              |
| ------------- | --------------------------------- |
| **`options`** | <code>{ version: string; }</code> |

**Returns:** <code>any</code>

--------------------


### delete(...)

```typescript
delete(options: { version: string; }) => any
```

delete version in storage

| Param         | Type                              |
| ------------- | --------------------------------- |
| **`options`** | <code>{ version: string; }</code> |

**Returns:** <code>any</code>

--------------------


### list()

```typescript
list() => any
```

get all avaible verisions

**Returns:** <code>any</code>

--------------------


### load()

```typescript
load() => any
```

load current version

**Returns:** <code>any</code>

--------------------

</docgen-api>


### Inspiraton

- [cordova-plugin-ionic](https://github.com/ionic-team/cordova-plugin-ionic)
- [capacitor-codepush](https://github.dev/mapiacompany/capacitor-codepush)
