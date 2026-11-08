# Privacy and Security

## What Player sends over the network

Player sends nothing to v57. There's no server of ours, no analytics and no crash reporter. It doesn't look up titles,
artwork or subtitles online. Player contacts these, and only for these reasons:

| Who | When | What they see |
|---|---|---|
| Your other devices, over SSH | You use **Open from Device…** | A sign-in with Player's own key, the folders you browse and the video you play |
| GitHub | You choose **Player ▸ Check for Updates…**, or daily if you turned on **Check for Updates Automatically** | Your IP address |
| Apple's iCloud | While **Use iCloud** is on | Your vault's records (your devices and hosts), encrypted on this Mac first |

**Check for Updates Automatically** is off when you install Player. An update downloads only when you say so.

## Your videos stay where they are

Player never changes, moves or deletes a video. It keeps only its own history on this Mac: where you stopped in each
video, your track choices and your recent videos. Your audio mode, loudness and subtitle style are kept with Player's
settings.

## Keys and passwords

- **Open from Device…** signs in with Player's own key, kept in this Mac's Secure Enclave. You allow it per Mac in
  **Vault ▸ Settings ▸ Remote ▸ Apps on Your Devices**, with **Can Sign In**. It can only read files there: no terminal
  and no tunnels.
- Player can't read your saved passwords or your device's key. A host that takes a password says so instead.
- The first time Player connects to a device, it shows the device's key and asks **Trust this server's key?**. Nothing
  is sent to the device before you click **Trust and Connect**.

## iCloud

**Player ▸ Settings… ▸ Privacy** has the **Use iCloud** switch. It's the same switch in every v57 app on this Mac.
Player uses iCloud for one thing: the list of your devices for **Open from Device…**.

To turn it off, switch **Use iCloud** off and confirm **Turn Off iCloud?**. Every v57 app on this Mac stops syncing
through iCloud and iCloud Keychain. What's already in iCloud stays, and your other devices keep it. Turn it back on to
sync again.
