# capacitor-updater

Download app update from url and install it.

And reload the view.

You can list the version and manage it with the command below.

## Community
Join the discord to get help : https://discord.gg/VnYRvBfgA6

## Install

```bash
npm install capacitor-updater
npx cap sync
```

```
  import { CapacitorUpdater } from 'capacitor-updater'
  import { SplashScreen } from '@capacitor/splash-screen'
  import { App } from '@capacitor/app'

  let version = ""
  App.addListener('appStateChange', async(state) => {
      if (state.isActive) {
        // Do the download during user active app time to prevent failed download
        version = await CapacitorUpdater.download({
        url: 'https://github.com/Forgr-ee/Mimesis/releases/download/0.0.1/dist.zip',
        })
      }
      if (!state.isActive && version !== "") {
        // Do the switch when user leave app
        SplashScreen.show()
        try {
          await CapacitorUpdater.set(version)
        } catch () {
          SplashScreen.hide() // in case the set fail, otherwise the new app will have to hide it
        }
      }
  })

  // or do it when click on button
  const updateNow = async () => {
    const version = await CapacitorUpdater.download({
      url: 'https://github.com/Forgr-ee/Mimesis/releases/download/0.0.1/dist.zip',
    })
    // show the splashscreen to let the update happen
    SplashScreen.show()
    await CapacitorUpdater.set(version)
    SplashScreen.hide() // in case the set fail, otherwise the new app will have to hide it
  }
```

*Be extra carufull for your update* if you send a broken update, the app will crash until the user uninstall it.

## Packaging `dist.zip`

Whatever you choose to name the file you download from your release/update server URL, the zip file should contain the full contents of your production Capacitor build output folder, usually `{project directory}/dist/`. This is where `index.html` will be located, and it should also contain all bundled JavaScript, CSS, and web resources necessary for your app to run.

Do not password encrypt this file, or it will fail to unpack.

## API

<docgen-index>

* [`download(...)`](#download)
* [`set(...)`](#set)
* [`delete(...)`](#delete)
* [`list()`](#list)
* [`reset()`](#reset)
* [`current()`](#current)
* [`reload()`](#reload)
* [`versionName()`](#versionname)
* [`notifyAppReady()`](#notifyappready)
* [`delayUpdate()`](#delayupdate)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### download(...)

```typescript
download(options: { url: string; }) => Promise<{ version: string; }>
```

download new version from url, it should be a zip file, with files inside or with a unique folder inside with all your files

| Param         | Type                          |
| ------------- | ----------------------------- |
| **`options`** | <code>{ url: string; }</code> |

**Returns:** <code>Promise&lt;{ version: string; }&gt;</code>

--------------------


### set(...)

```typescript
set(options: { version: string; versionName?: string; }) => Promise<void>
```

set version as current version, set will return error if there are no index.html file inside the version folder, versionName is optional and it's a custom value who will be saved for you

| Param         | Type                                                    |
| ------------- | ------------------------------------------------------- |
| **`options`** | <code>{ version: string; versionName?: string; }</code> |

--------------------


### delete(...)

```typescript
delete(options: { version: string; }) => Promise<void>
```

delete version in storage

| Param         | Type                              |
| ------------- | --------------------------------- |
| **`options`** | <code>{ version: string; }</code> |

--------------------


### list()

```typescript
list() => Promise<{ versions: string[]; }>
```

get all avaible versions

**Returns:** <code>Promise&lt;{ versions: string[]; }&gt;</code>

--------------------


### reset()

```typescript
reset() => Promise<void>
```

set the original version (the one sent to Apple store / Google play store ) as current version

--------------------


### current()

```typescript
current() => Promise<{ current: string; }>
```

get the curent version, if none are set it return 'default'

**Returns:** <code>Promise&lt;{ current: string; }&gt;</code>

--------------------


### reload()

```typescript
reload() => Promise<void>
```

reload the view

--------------------


### versionName()

```typescript
versionName() => Promise<{ versionName: string; }>
```

Get the version name, if it was set during the set phase

**Returns:** <code>Promise&lt;{ versionName: string; }&gt;</code>

--------------------


### notifyAppReady()

```typescript
notifyAppReady() => Promise<void>
```

notify native plugin that the update is working

--------------------


### delayUpdate()

```typescript
delayUpdate() => Promise<void>
```

skip update in the next app backgrounding

--------------------

</docgen-api>


### Inspiraton

- [cordova-plugin-ionic](https://github.com/ionic-team/cordova-plugin-ionic)
- [capacitor-codepush](https://github.dev/mapiacompany/capacitor-codepush)


### Contributer

[jamesyoung1337](https://github.com/jamesyoung1337) Thanks a lot for your guidance and support, it was impossible to make this plugin work without you.
