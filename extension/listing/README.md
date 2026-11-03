# Publishing the extension

Everything the Chrome Web Store and Firefox Add-ons ask for, ready to paste. One Chrome Web Store listing covers
Chrome, Edge, Brave, Arc and Dia; Firefox has its own.

## 1. Build the packages

```bash
./extension/store.sh pack
```

This writes `extension/store/satchel-chrome-<version>.zip` (without the `key` field, which the store refuses on a new
item) and `extension/store/satchel-firefox-<version>.zip`.

## 2. Chrome Web Store

1. Register once at https://chrome.google.com/webstore/devconsole ($5, one time).
2. **New item**: upload the Chrome zip.
3. Fill in the **Store listing**, **Privacy** and **Distribution** tabs with the text below.
4. **Submit for review.** A first review usually takes a few days; access to all sites can make it longer.
5. **After the first upload:** in the dashboard, open **Package → View public key**, copy it, then run:

```bash
./extension/store.sh set-chrome-key "<the public key>"
```

This makes the store's extension ID the one everywhere: the manifest, the app's native-messaging allow list and the
smoke test. Commit the change. The next app release accepts the store extension. Later uploads keep the key, so the
ID never changes again.

## 3. Firefox Add-ons

1. Sign in at https://addons.mozilla.org/developers/ (free).
2. **Submit a new add-on → On this site**, upload the Firefox zip.
3. "Do you need to submit source code?" **No**: the code is not minified or bundled.
4. Fill in the listing with the text below. The ID `satchel@bilalesi` is fixed, so the app already accepts it.

`npx web-ext lint -s extension/dist/firefox` reported no errors and no warnings on version 0.2.4.

## Listing text

**Name:** Satchel

**Summary** (Chrome: up to 132 characters; Firefox: up to 250):

> Fill logins from Satchel, the password manager for your Mac. Your vault stays on your Mac; the extension collects nothing.

**Description:**

> Satchel brings your Satchel vault to the browser. On any site, it shows the logins saved for that site, right
> under the login field and in the toolbar. Choose one to fill it, or copy the username, the password or the
> one-time code.
>
> Only the right site gets your login. Satchel matches the real domain of the page, so a look-alike site gets
> nothing, and nothing is filled until you choose a login.
>
> Your vault stays on your Mac. The extension talks only to the Satchel app on the same Mac, through the browser's
> native messaging. It makes no network requests, keeps no data and collects nothing.
>
> Needs the Satchel app for macOS: https://satchel.echospace.dev
>
> Keyboard: ⌘⇧L fills the best match on the page.

**Category:** Chrome: Tools (Productivity). Firefox: Privacy & Security.

**Language:** English

**Images:** `1-popup.png`, `2-quick-access.png`, `3-app.png` (1280×800). Chrome's small promo tile is
`promo-tile-440x280.png`. The store icon is `extension/src/icons/128.png`.

**Website:** https://satchel.echospace.dev
**Support:** satchel@echospace.dev
**Privacy policy:** https://satchel.echospace.dev/privacy

## Chrome: Privacy tab

**Single purpose:**

> Fill and copy logins saved in the user's Satchel app on the same Mac, on the site they belong to.

**Permission justifications:**

| Permission | Justification |
|---|---|
| `nativeMessaging` | The extension's only data source is the Satchel app on the same Mac. Native messaging is how it asks the app for the logins that match the current site. |
| `activeTab` | Reads the current tab when the user opens the popup or presses the fill shortcut, so the matching logins can be shown and filled. |
| `tabs` | Reads the address of the active tab, so the app can match logins to the site's domain. A login is only offered on its own site. |
| `clipboardWrite` | Copies a username, password or one-time code when the user clicks Copy. |
| Host access (`http://*/*`, `https://*/*`) | Shows the saved logins under login fields on whatever site the user signs in to. A password manager cannot know in advance which sites those are. On each page it only looks for login fields. It reads what the user typed into them only when they click Save this login. Nothing is sent anywhere but the app on the same Mac. |

**Remote code:** No, I am not using remote code.

**Data usage:** tick **Authentication information** only (logins are handled to fill them). Then tick all three
statements:

- I do not sell or transfer user data to third parties, outside of the approved use cases.
- I do not use or transfer user data for purposes that are unrelated to my item's single purpose.
- I do not use or transfer user data to determine creditworthiness or for lending purposes.

## Firefox: data collection

The manifest declares `data_collection_permissions: { required: ["none"] }`: the extension collects nothing. In the
listing's privacy section, link https://satchel.echospace.dev/privacy.
