# Open from Device

**Open from Device…** plays a video that's on another of your devices, such as a Hub device or another Mac. Player
reads the file over SFTP as it plays. Nothing is copied to this Mac first.

## Before you start

- The device must be in your vault. [Vault](https://github.com/v57/Vault/blob/main/docs/README.md) lists your Hub
  devices and the Macs that let your devices in. A Mac lets your devices in with **Vault ▸ Settings ▸ Remote ▸ Let Your
  Devices In**, which needs Remote Login on. The Mac you're using isn't listed.
- Player signs in with its own key, not your device's key. The first time you open a device that's a Mac, Player adds
  its key to your vault. On that Mac, open **Vault ▸ Settings ▸ Remote**. Under **Apps on Your Devices**, find Player on
  this Mac and turn on **Can Sign In**. Until you do, the sign-in fails.

## Play a video from a device

1. Choose **File ▸ Open from Device…** (**⇧⌘O**), or **Open from Device…** on the welcome screen.
2. Under **Devices**, pick the device. If you have more than one vault account, pick the account in the **Devices**
   header first.
3. Player opens your home folder on that device. It lists folders first, then the videos it can play, with their
   sizes. Hidden files aren't listed.
4. Open folders to find the video. Click **Up** to go to the parent folder, or **Devices** to pick another device.
5. Click a video. The sheet closes and the video plays.

Player reads ahead while the video plays, and keeps what it has read, so going back is quick. Your place is remembered
for that video on that device.

Click **Cancel** or press **Esc** to close the sheet.

If no devices are listed, the sheet says **No Devices**. Add your Hub in the Vault app; its devices that offer SSH
show up here.

## The first connection to a device

The first time Player connects to a device whose key it doesn't know, it asks **Trust this server's key?** with the
device's name and address. Nothing is sent before you answer. Click **Trust and Connect** to go on; Vault remembers the
key. Click **Cancel** to stop.

If your Mac's key needs you to confirm, macOS asks for Touch ID or your password when Player signs in.

## When something goes wrong

- **A device that takes a password:** Player never reads a saved password. It says the host takes a password: allow
  Player on that Mac in **Vault ▸ Settings ▸ Remote** and set the host to sign in with a key.
- **A device that doesn't answer:** Player tries the device's other addresses first. If none answers, it shows
  **Couldn’t reach the device.** with the reason.
