# Changelog

All notable changes to this project will be documented in this file. See [standard-version](https://github.com/conventional-changelog/standard-version) for commit guidelines.

## [4.0.0-alpha.8](https://github.com/Cap-go/capacitor-updater/compare/4.0.0-alpha.7...4.0.0-alpha.8) (2022-07-01)


### Bug Fixes

* build issue ios ([fe02774](https://github.com/Cap-go/capacitor-updater/commit/fe0277429b6e8342ddcb8f638427f590cf067045))

## [4.0.0-alpha.7](https://github.com/Cap-go/capacitor-updater/compare/4.0.0-alpha.6...4.0.0-alpha.7) (2022-07-01)


### Bug Fixes

* web ([9f0131c](https://github.com/Cap-go/capacitor-updater/commit/9f0131c24645c8515722e030cdad45df31183e41))

## [4.0.0-alpha.6](https://github.com/Cap-go/capacitor-updater/compare/4.0.0-alpha.5...4.0.0-alpha.6) (2022-07-01)


### Bug Fixes

* definitions ([78fd247](https://github.com/Cap-go/capacitor-updater/commit/78fd2472378f4f8f17e849420c0a6c806bfb764b))

## [4.0.0-alpha.5](https://github.com/Cap-go/capacitor-updater/compare/4.0.0-alpha.4...4.0.0-alpha.5) (2022-07-01)


### Bug Fixes

* _reset use new system ([ed6b751](https://github.com/Cap-go/capacitor-updater/commit/ed6b7514d24b2fe7e147c7fc5d291d08e92fad57))

## [4.0.0-alpha.4](https://github.com/Cap-go/capacitor-updater/compare/4.0.0-alpha.3...4.0.0-alpha.4) (2022-07-01)


### Bug Fixes

* rename autoUpdateUrl in updateUrl ([169676c](https://github.com/Cap-go/capacitor-updater/commit/169676cb9c15cb3cc2030dba4717fe64068e0f73))

## [4.0.0-alpha.3](https://github.com/Cap-go/capacitor-updater/compare/4.0.0-alpha.2...4.0.0-alpha.3) (2022-07-01)


### Features

* expose getLatest in js ([813fee4](https://github.com/Cap-go/capacitor-updater/commit/813fee461d26158354ca51011b1d93c70ea1d64c))

## [4.0.0-alpha.2](https://github.com/Cap-go/capacitor-updater/compare/4.0.0-alpha.1...4.0.0-alpha.2) (2022-07-01)


### Bug Fixes

* publish on npm as next for dev ([f545390](https://github.com/Cap-go/capacitor-updater/commit/f545390e33c36019fc33dddf2c5a9921ebf923ba))

## [4.0.0-alpha.1](https://github.com/Cap-go/capacitor-updater/compare/3.2.1-alpha.0...4.0.0-alpha.1) (2022-07-01)


### Bug Fixes

* version issue ([4ca4c31](https://github.com/Cap-go/capacitor-updater/commit/4ca4c31c930653eb8a9dd8f23b71bb87a9ba8e21))

## [4.0.0-alpha.0](https://github.com/Cap-go/capacitor-updater/compare/3.3.2...4.0.0-alpha.0) (2022-07-01)


### ⚠ BREAKING CHANGES

* **android:** Java and TypeScript interfaces have changed for some plugin methods to support returning VersionInfo

### Features

* add DownloadComplete event and remove updateAvailable ([1cbc934](https://github.com/Cap-go/capacitor-updater/commit/1cbc934849bea779c6efe154d63d1b19cd1b16b8))
* add event when fail install ([e68a4d3](https://github.com/Cap-go/capacitor-updater/commit/e68a4d3c864002b8da6b74778c035bef021f2c93))
* add to download event version ([2069379](https://github.com/Cap-go/capacitor-updater/commit/206937965ee19e3bc23bb041f12df470d941894f))
* **android:** support notifyAppReady() in manual mode ([b894788](https://github.com/Cap-go/capacitor-updater/commit/b89478849997d3d9d3c849d6e9ccc3e63ac187f7))
* use post instead of get for update ([f763cb5](https://github.com/Cap-go/capacitor-updater/commit/f763cb5b6cf8e16eb1e53c0d736289cabf7a7cfa))


### Bug Fixes

* add cleanup ios ([c412bf4](https://github.com/Cap-go/capacitor-updater/commit/c412bf4b217c64e3f652620abbba16408b2ce632))
* add comment for easy understanding ([9c59c02](https://github.com/Cap-go/capacitor-updater/commit/9c59c02584790f784ce274e718fc341a95f10769))
* add DeferredNotifyAppReadyCheck and checkAppReady ([ea2f18b](https://github.com/Cap-go/capacitor-updater/commit/ea2f18b573ab4f7141ce1489509d93fe21639791))
* add message from backend to display to users ([e6fd0f2](https://github.com/Cap-go/capacitor-updater/commit/e6fd0f2cdfb4d722083e0ec7d0fc32d37ca7ad9d))
* add missign methods in swift ([c98ba70](https://github.com/Cap-go/capacitor-updater/commit/c98ba702a4195902f6af4776c4527477a20eeaaa))
* add missing class in swift ([ff80a4d](https://github.com/Cap-go/capacitor-updater/commit/ff80a4d3bec3467be443f0cc9a8d423171d04eeb))
* add missing definitions ([4127f0f](https://github.com/Cap-go/capacitor-updater/commit/4127f0fdaec89194c86ad6e92cb38310443c67c3))
* add missing method ([712deea](https://github.com/Cap-go/capacitor-updater/commit/712deea07638ac1f0df839333f572e72b1996012))
* add next method ([ca5a0f4](https://github.com/Cap-go/capacitor-updater/commit/ca5a0f4930c10553c6705827a68678e429e6f8f6))
* all prebuild issue ([1bd38ab](https://github.com/Cap-go/capacitor-updater/commit/1bd38ab240b2d67b8319e3e58773d495250f0c83))
* allow store object in pref ([b16b8ff](https://github.com/Cap-go/capacitor-updater/commit/b16b8ff2d471950e6ca29afc55c534166296306c))
* **android:** autoUpdate properly compares version names during getLatest check ([9e5c37c](https://github.com/Cap-go/capacitor-updater/commit/9e5c37cf6be677e6264978a11f750875e2db342d))
* **android:** code style ([13475a4](https://github.com/Cap-go/capacitor-updater/commit/13475a42c5a67ba753c59a9a96091f93ffc4bc25))
* **android:** dont allow redundant downloads of versions that already exist ([e9f81d7](https://github.com/Cap-go/capacitor-updater/commit/e9f81d7b118ad08ba6c6e3b5973fed3e2767fe2a))
* **android:** ensure correct bundle properties are used when saving fallback version ([caac9dc](https://github.com/Cap-go/capacitor-updater/commit/caac9dc336bd19ec9e60071ca5ee7ae0e2ca7197))
* **android:** event listener calls should return bundle not version, as appropriate ([2d1e180](https://github.com/Cap-go/capacitor-updater/commit/2d1e180bcd67234eefeed9370a48501f8c19b7de))
* **android:** extra safe plugin API calls ([2f09660](https://github.com/Cap-go/capacitor-updater/commit/2f096607547068ecef36aaf91fcfd59d65dee645))
* **android:** fix file api usage ([04783df](https://github.com/Cap-go/capacitor-updater/commit/04783df2d5474f6ac5ab0aa490c51e4039f93b57))
* **android:** fix incorrectly keyed json accessors ([6071bfa](https://github.com/Cap-go/capacitor-updater/commit/6071bfa056cdd150a16734a06c7e90423357d194))
* **android:** function getting bundle by name should actually compare using name ([b9d7e67](https://github.com/Cap-go/capacitor-updater/commit/b9d7e6787db5c57f5b7270687ae8fac91369f611))
* **android:** handle CAP_SERVER_PATH empty string as default equivalent to 'public' ([ea80afe](https://github.com/Cap-go/capacitor-updater/commit/ea80afea15548711125b7a36e3792f03e68964cb))
* **android:** next() function should set version status to PENDING ([b0c1181](https://github.com/Cap-go/capacitor-updater/commit/b0c118116f15259fdc98d452cd94ec16a880935d))
* **android:** onActivityStarted needs to be called in ALL modes ([cd0b1aa](https://github.com/Cap-go/capacitor-updater/commit/cd0b1aad71cc977b78b1269c8e661031288df849))
* **android:** use correct bundle property for commit/rollback ([0839230](https://github.com/Cap-go/capacitor-updater/commit/08392300af8187a224064b614dd26915003ffe43))
* appMovedToForeground ([9f054ed](https://github.com/Cap-go/capacitor-updater/commit/9f054ed8bbbfff8b09e214b1f0c813cc755583bf))
* auto update ([d170455](https://github.com/Cap-go/capacitor-updater/commit/d1704559b371af7d223d77ee0fd3df53b3232d29))
* auto update ([8fbae64](https://github.com/Cap-go/capacitor-updater/commit/8fbae647a3e70da639e72ffc4b711a136ae9adc3))
* build issue android ([8ff71af](https://github.com/Cap-go/capacitor-updater/commit/8ff71af4d2c3aee2136bd9cbf33ecf6d46e187ea))
* cleanupObsoleteVersions ([1fa7d97](https://github.com/Cap-go/capacitor-updater/commit/1fa7d97501130d871e6048b7ba64f6b2291efc9c))
* def issue ([ba0f506](https://github.com/Cap-go/capacitor-updater/commit/ba0f506b1dbbde04b92b2d2b6c873fbe78aae086))
* definitions ([3efc1cb](https://github.com/Cap-go/capacitor-updater/commit/3efc1cb7d048375c81c67541253eb59b5a7aefb9))
* definitions ([0f62af4](https://github.com/Cap-go/capacitor-updater/commit/0f62af45456a81b949ce06a33ce10726d384d8dd))
* doc ([31fbe56](https://github.com/Cap-go/capacitor-updater/commit/31fbe562c365a5bd425dac48d9baf7214504f309))
* doc ([b1a8a3e](https://github.com/Cap-go/capacitor-updater/commit/b1a8a3ed521e01b2f2a542ed80bb4ca02c2ca88a))
* download missign methods calls ([719d2f5](https://github.com/Cap-go/capacitor-updater/commit/719d2f5dd5f8f43803ac4afe22ad98a75968a0d4))
* error message ([cceec00](https://github.com/Cap-go/capacitor-updater/commit/cceec00fc179c2be0d0245f4803e0d865f2ec101))
* expose isAutoUpdateEnabled ([b0befb1](https://github.com/Cap-go/capacitor-updater/commit/b0befb11dacf58e447ec642752c028b53c4d21f8))
* folder default issue ([6ea750f](https://github.com/Cap-go/capacitor-updater/commit/6ea750f52c181fa9d9d6d0b7bdc430ae0ad5b3df))
* function name ([f40dd5b](https://github.com/Cap-go/capacitor-updater/commit/f40dd5bc2ade3f36ac5bf9c654137a2dd3c75c65))
* function name ([a7a8001](https://github.com/Cap-go/capacitor-updater/commit/a7a80017aa025f48dd96ecb4b3a3590c80bd0ee8))
* implement setCurrentBundle ([b8a3e56](https://github.com/Cap-go/capacitor-updater/commit/b8a3e567a010298f68fb2787c593e0aeb5a30e33))
* info and status ([67998a5](https://github.com/Cap-go/capacitor-updater/commit/67998a5419356a78788d73ba6278e08ea258ebf9))
* install instruction ([8b8523e](https://github.com/Cap-go/capacitor-updater/commit/8b8523ea209474a3e6bbcb09ba662da7c8ef7258))
* ios part ([2ff3224](https://github.com/Cap-go/capacitor-updater/commit/2ff3224f8fc403e70b376c6d8a28ad18657de708))
* ios settings ([8770d23](https://github.com/Cap-go/capacitor-updater/commit/8770d23c4cbe3e3427e6212719b0fa60a26b40bc))
* issue cleanup ([6c6e395](https://github.com/Cap-go/capacitor-updater/commit/6c6e3956f03793e6c3cee6ef212de51bd5e1f9fb))
* issue naming in versionInfo ([24c552a](https://github.com/Cap-go/capacitor-updater/commit/24c552a24fd6d77b769b8dcc3d161efaa054553a))
* issue set ([6d7b01c](https://github.com/Cap-go/capacitor-updater/commit/6d7b01c72b0265f1cf19dccb79a4ce34af8192eb))
* issue with isBuiltin is Unknow ([0a6d963](https://github.com/Cap-go/capacitor-updater/commit/0a6d963e5991e89bf59f497844ae1d570017f995))
* last compilation fail ([c593f8b](https://github.com/Cap-go/capacitor-updater/commit/c593f8bfddcc98762b9d44371200100ce137b1c5))
* last missgin diff in swift ([bf7f97a](https://github.com/Cap-go/capacitor-updater/commit/bf7f97afb86d28de33474446d58050ba5e52f566))
* logs again ([9e54db5](https://github.com/Cap-go/capacitor-updater/commit/9e54db5de836b052c3b979f531d07fe26542c080))
* logs messages ([e0d9bf5](https://github.com/Cap-go/capacitor-updater/commit/e0d9bf554924b1cbad465e2febe9ec94af6b4aee))
* make android file closer to ios one ([c584e9d](https://github.com/Cap-go/capacitor-updater/commit/c584e9d8caf0d5432a1c947d65917fbc77ca6b8f))
* merge issue ([0e14bcd](https://github.com/Cap-go/capacitor-updater/commit/0e14bcdf381af2d05e0dccab0d8a0f87410241fb))
* merge issue ([bbdbafd](https://github.com/Cap-go/capacitor-updater/commit/bbdbafdc85581baa0967a3a18907f5e30ee8bac6))
* missign delete in ios ([008c8a8](https://github.com/Cap-go/capacitor-updater/commit/008c8a8f770293455f07b69987bcc9e73a796e77))
* name folder to id ([fe789a3](https://github.com/Cap-go/capacitor-updater/commit/fe789a3df79b5f963af792510766473c5786aa9c))
* notifyAppReady ios ([92de32e](https://github.com/Cap-go/capacitor-updater/commit/92de32e0c0c2334b8986401579605dcce81d2358))
* order ([c6a0ca4](https://github.com/Cap-go/capacitor-updater/commit/c6a0ca4960e0b9269b0a7e3007f7ddc18ec64713))
* put back old number version ([0866064](https://github.com/Cap-go/capacitor-updater/commit/086606406feb4cdc6abf6c6cffed6fa49d372656))
* reload and logs ([8c963ab](https://github.com/Cap-go/capacitor-updater/commit/8c963ab95370f5a58139d02e325fa4f4d83c9253))
* remove debug comment ([cd21c96](https://github.com/Cap-go/capacitor-updater/commit/cd21c9623cb409efd59783fb928af8e0b9e2cdca))
* remove getter and setters ([a4c0c58](https://github.com/Cap-go/capacitor-updater/commit/a4c0c5879ec6b48885b38e3949e63e6d68006f29))
* remove old code ([e168824](https://github.com/Cap-go/capacitor-updater/commit/e1688241127631e22f6f209d87163f4a76bb1430))
* remove useless import ([131fb2a](https://github.com/Cap-go/capacitor-updater/commit/131fb2a4b8f584abf00b851f5e194835338a44ea))
* remove versionName from next ([7df3471](https://github.com/Cap-go/capacitor-updater/commit/7df3471d098edf04c135c78f9e62fe9d9746c7f8))
* reset ([c16c597](https://github.com/Cap-go/capacitor-updater/commit/c16c597f4ffaa72e3b98b4c0b917203b956938d4))
* save and download issue ([d325ec9](https://github.com/Cap-go/capacitor-updater/commit/d325ec98aaa04d1e7623a013bd08273fb814ddf6))
* saveVersionInfo implem ([be2dce0](https://github.com/Cap-go/capacitor-updater/commit/be2dce00688cf4c0d2d7ba54ac4ee5d3977c5a55))
* sendStats in android and updateFailed position ([fd3e744](https://github.com/Cap-go/capacitor-updater/commit/fd3e7445dc5daa02648019bb65bece513b4d9b32))
* some other logs ([1e82ece](https://github.com/Cap-go/capacitor-updater/commit/1e82ece85b892c232895976c7c40f61a6a421ee9))
* use bundle instead of version in appropriate places (affects both typescript and java, possibly ios) ([2a40471](https://github.com/Cap-go/capacitor-updater/commit/2a40471d0d062268b87d5639ffa936278937ec5f))
* use only ont TAG in the whole code ([2ad10ec](https://github.com/Cap-go/capacitor-updater/commit/2ad10ec36a12ad64dc068f0af53737d3119f3bd6))
* useless stored var ([3fdae2b](https://github.com/Cap-go/capacitor-updater/commit/3fdae2b74799fd9f97caec0fbaf63d6872d92c18))
* versionInfo and Status ([b64aa04](https://github.com/Cap-go/capacitor-updater/commit/b64aa04168e623afa0825fed548a4e7066f2bd0c))
* versionInfo to BundleInfo ([d5c300e](https://github.com/Cap-go/capacitor-updater/commit/d5c300e1c25dab7834875d0c216117aa9ba562ff))
* web ([9bdf9cc](https://github.com/Cap-go/capacitor-updater/commit/9bdf9cca4e866b4bda8e166984bfb386e1edd631))

## 3.3.2 (2022-05-04)

### Fix

- **android**: Fix typo in 'getPluginVersion'

## 3.3.1 (2022-05-04)

### Fix

- add missing def ios

## 3.3.0 (2022-05-04)

### Fix

- add getPluginVersion
- remove duplicated var
- better error handling download function
- lint
- order
- var order
- some issue in order
- remove event for now to have simple interface

### Feat

- **android**: download method bubbles exception to client

## 3.2.1 (2022-04-29)

### Fix

- doc link issue

## 3.2.0 (2022-04-22)

### Feat

- add os version in metadata

## 3.1.0 (2022-04-20)

### Feat

- add versionCode in stats and update

## 3.0.10 (2022-04-20)

### Fix

- reset issue android cannot hot reload

## 3.0.9 (2022-04-19)

### Fix

- order issue resetWhenUpdate

## 3.0.8 (2022-04-16)

### Fix

- issue android

## 3.0.7 (2022-04-16)

### Fix

- naming

## 3.0.6 (2022-04-16)

### Fix

- file npm

## 3.0.5 (2022-04-16)

### Fix

- naming issue

## 3.0.4 (2022-04-16)

### Fix

- doc

## 3.0.3 (2022-04-16)

### Fix

- again issue typo version npm

## 3.0.2 (2022-04-16)

### Fix

- issue in release naming

## 3.0.1 (2022-04-16)

### Fix

- tigger CI

## 3.0.0 (2022-04-16)

### Fix

- issue path for auto version update
- tigger CI
- wrong version send
- pack version
- android build
- version number
- remove call when not necessary
- send builtin if no version
- platform
- typing issue
- typing
- def issue
- remove auto update logic from app
- issue with OSX hidden folder

### Feat

- make auto update server side first
- add pluginVersion send to server
- reset on update by default.
- add currentNative to get current
- add updateAvailable event
- add getId method for version by device control
- :boom: use the new auto update system
- add headers to getLatest for future usage

### BREAKING CHANGE

- the url config change and not compatible with the past one

## 2.3.3 (2022-04-05)

### Fix

- persistent path issue during delete
- persistent path issue during delete

## 2.3.2 (2022-03-31)

### Fix

- issue in android with new event

## 2.3.1 (2022-03-31)

### Fix

- npm listing

## 2.3.0 (2022-03-31)

### Feat

- add majorAvailable event

## 2.2.6 (2022-03-28)

### Fix

- documentation

## 2.2.5 (2022-03-28)

### Fix

- issue conversion

## 2.2.4 (2022-03-28)

### Fix

- init version

## 2.2.3 (2022-03-28)

### Fix

- init value for version ios
- build error ios

## 2.2.2 (2022-03-28)

### Fix

- version issue ios

## 2.2.1 (2022-03-28)

### Fix

- issue with resetWhenUpdate

## 2.2.0 (2022-03-28)

### Feat

- add resetWhenUpdate system

### Fix

- error in ios missing code disableAutoUpdateUnderNative

## 2.1.1 (2022-03-26)

### Fix

- use demo-app in the doc

## 2.1.0 (2022-03-26)

### Feat

- add disableAutoUpdateUnderNative and disableAutoUpdateToMajor capability

## 2.0.16 (2022-03-25)

### Fix

- issue with download percent

## 2.0.15 (2022-03-24)

### Fix

- doc add link for API key

## 2.0.14 (2022-03-24)

### Fix

- add missing keywork in set step

## 2.0.13 (2022-03-24)

### Fix

- better documentation for auto update

## 2.0.12 (2022-03-22)

### Fix

- add definition for download event

## 2.0.11 (2022-03-16)

### Fix

- keywords  npm

## 2.0.10 (2022-03-14)

### Fix

- type def for reset

## 2.0.9 (2022-03-14)

### Fix

- issue ios copy

## 2.0.8 (2022-03-10)

### Fix

- remove duplicated code and allow init without plugin

## 2.0.7 (2022-03-09)

### Fix

- broken version system ios
- background thread issue ios

## 2.0.6 (2022-03-08)

### Fix

- last typo issue
- typo

## 2.0.5 (2022-03-08)

### Fix

- typo again

## 2.0.4 (2022-03-08)

### Fix

- typo issue

## 2.0.3 (2022-03-07)

### Fix

- build issue

## 2.0.2 (2022-03-07)

### Fix

- build issue

## 2.0.1 (2022-03-07)

### Fix

- build issue

## 2.0.0 (2022-03-07)

### BREAKING CHANGE

- change default to builtin as default value

## 1.5.1 (2022-03-07)

### Fix

- typo in text

## 1.5.0 (2022-03-07)

### Fix

- remove lint in CI for now
- log messages make them same between platforms
- remove unzip logs
- upgrade version for publication
- android log
- android download issue in evnt system
- log messages android
- remove just dependency
- remove useless doc
- stats use config appId
- android
- SecurityException start path
- documentation links
- make doc beatifull
- documentation in npm
- android issue
- if empty folder
- typo android stats
- android stats methods
- android stats method
- delay android
- issue build
- async get version issue
- remove error with this android
- dispatch async ios
- make first check async
- missing reset versionName
- reset function issue android
- reset function issue android
- android for capacitor-go usage
- typedef
- reset function
- reset for ios
- reset android
- remove bad return
- last android typo
- package
- persistence in android
- current and disable reset in ios for now
- add missing function declarion ios
- typo
- file exist issue
- add back build.gradle mistaken deleted
- update version number missing
- update version number for android version
- docgen
- make persistency work too
- reload only if lastPath set
- give more freedom to dev who use the plugin
- persist version between reload
- make version install work on ios
- path issue
- import ios
- use android studio to catch errors

### Feat

- allow reset to auto update version + add CI
- add download event
- add stats methods
- add cancel delay
- add delayupdate
- release minor version for new feature availability
- make auto update revert if fail to load
- make live update work in IOS and Android
- add versionName and reload + WIP auto update
- add current method
- add reset method to revert to original
- add persistency android
- make hotreload work in Android
- add methods to decouple update
- add just and reload
- make unzip and copy step
- add base of ios, download file
- transfor android and ios with necessary base
- add web definition
