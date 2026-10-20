# Graphics

The graphics layer follows X11 rather than a toy desktop: a display server
belongs to the machine, a window manager is a separate program, a session is
started by a login screen.

## Display server and window manager

- **Display server.** `AgoraDisplay` (`kernel/display/`) belongs to a box with a
  monitor. A headless box has none, so `terminal` on a server or from an ssh
  session fails with "cannot open display". Windows belong to processes and
  close when their process exits. Windows sit on layers DESKTOP, NORMAL, PANEL
  or OVERLAY; a panel reserves a screen edge with `set_strut`.
- **On screen.** `AgoraDisplayView` shows a display in the scene tree, with the
  text console (`tty1`) under all windows; typing goes to the console when no
  window has focus.
- **Window manager.** `wm` registers with the display and frames every window.
  Kill it and windows become bare; start it again and they get frames back. The
  look comes from `/usr/share/themes/<name>/wm.theme`, chosen by
  `~/.config/wm.conf` or `/etc/wm.conf`.

## The session

`greeter` (the login screen, a service) runs as root and checks the password
against `/etc/shadow`, then runs `~/.xinitrc` or `/etc/X11/xinitrc` as the user
in a new session. The default script starts `desktop &`, `panel &`,
`terminal &` and then `wm`, so the session ends when `wm` exits; the greeter
then kills what is left of the session and shows the login screen again.
Session output goes to `~/.xsession-errors`, logins to `/var/log/auth.log`.
`/etc/greeter.conf` can log a user in automatically.

## Programs

Windowed programs extend `AgoraGuiProgram` (`$DISPLAY` lookup, `open_window`);
`AgoraDialog` draws modal dialogs inside a window; `AgoraStyle` has the font and
icons drawn in code.

- `panel`: taskbar (buttons of windows with `urgent` set blink until they
  are focused), the notification area (`display.tray_add(process, icon,
  tooltip, on_click)`, `tray_set`, `tray_remove`; icons go with their
  process), the clock and the application menu, built from
  `/usr/share/applications/*.desktop`.
- `desktop`: `~/Desktop` as icons (new users get it from `/etc/skel`).
- `terminal`: a pseudo-terminal (`pts/N`) running `$SHELL` in an
  `AgoraTermView`.
- `files`: the file manager, with the user's own permissions; copy, move and
  delete run the real `cp`, `mv` and `rm`.
- `edit`: text editor; files it can't write open read-only; asks before
  discarding changes.
- `view`: PNG, JPEG and WebP images.
- `open FILE`: like xdg-open. The type comes from `/etc/mime.types` or
  sniffing; the app from `MimeType=` lines in `.desktop` files, overridden by
  `~/.config/mimeapps.list`. Executables open in a terminal.

## Kestrel Navigator

The graphical web browser (`gui/apps/kestrel.gd`, the text/html application).
File (New Window, Open Location, Save As, View Source, Close), Edit (Copy,
Select All, Find in Page, Find Again), Go (back, forward, home, recent pages),
Bookmarks (Netscape's bookmarks.html in `~/.kestrel`, defaults in
`/etc/kestrel/bookmarks.html`), history (visited link colours), the homepage
from `/etc/kestrel/kestrel.conf`, Netscape 4 style status messages and error
pages, an animated logo, User-Agent "Mozilla/4.0 (compatible; Kestrel/1.0;
AgoraOS)", `about:`, `file:`, plain text and images shown directly, other types
offered for saving. Framesets: `rows=`/`cols=` (pixels, percent, `*`),
nested sets, `scrolling=no`; each frame loads its own document; a link goes to
its `target` (or `<base target>`): the same frame, another by name, the whole
window (`_top`, `_parent`), or a new window (`_blank`, or a name no frame has).

The engine is `AgoraHtmlView` (`gui/html_view.gd`): a forgiving DOM (implied
end tags, missing table rows, numbered forms), then layout into a display list:
collapsing block margins, inline runs with word wrap, headings, lists, `dl`,
`blockquote`, `pre`, `center` and `align`, `<font>`, b/i/u/tt/big/small, `hr`,
anchors, images (width/height, borders on links, alt boxes while loading),
tables (min/max column widths, colspan, rowspan on a grid of cells, width
px/%, cellpadding, cellspacing, border, bgcolor, align/valign), floating
images (`<img align=left|right>`: lines beside them are narrower, the next
float goes below when there is no room, `<br clear>` and a table go below
them). Form fields are real controls in a classic grey
theme and submit what Netscape sent. Selection by drag and double-click, Ctrl+A,
Ctrl+C to the system clipboard, case-insensitive find.

GIF: `AgoraGif` decodes GIF87a/89a itself (LZW, palettes, interlacing,
transparency, disposal methods 1-3, delays, NETSCAPE2.0 loops);
`AgoraGifTexture` is a Texture2D that picks the frame by the clock.

## Pigeon Mail

The mail client (`gui/apps/pigeon.gd`): toolbar (New Mail, Reply, Reply All,
Forward, Delete, Send/Recv, Addresses, New Folder, Accounts, Move To), folders
Inbox/Sent/Drafts/Trash and folders of one's own as mbox files in `~/Mail`
(unread in bold, counts on the folder), the message list (sorted by From,
Subject or Received when a column title is clicked, again for the other way),
the reading pane (the plain part, or text/html through `AgoraHtmlView`; the
attachments under the headers, each saved to the home folder with a click),
compose windows (To, Cc, Subject, Attach...; Send, Save Draft; replies quote
"----- Original Message -----" and "> "; forwarding keeps the attachments),
the address book (`~/.pigeon/addressbook`: New Contact, Add Sender, Delete,
Write To), automatic checks.

MIME is `AgoraMimeMail` (`kernel/mime_mail.gd`): multipart parts with their
boundaries, base64 and quoted-printable, charsets (us-ascii, iso-8859-1,
utf-8), RFC 2047 encoded words in headers, file names; and putting a message
together as Outlook Express did (multipart/mixed, the text 7bit or
quoted-printable, files in base64 with 76-character lines). The account in `~/.pigeon/account` (0600): incoming local
(`/var/mail/USER`) or POP3 (leave a copy, seen UIDLs), outgoing sendmail or
SMTP.

## Ping! Messenger

`pingmsg` (`gui/apps/pingmsg.gd`): login or "Get a new Ping! number", contact
list (Online / Offline / Not in list) with status lights, status menu, Add,
Find, a context menu (message, info, remove), a window per conversation (Enter
sends, Shift+Enter a new line), history in `~/.pingmsg/history/UIN`, the
account in `~/.pingmsg/account` (0600). `/etc/pingmsg.conf` names the server. An icon in
the notification area shows the status (an envelope while a message waits)
and shows or hides the list; a conversation with a new message blinks on the
taskbar; a message and a friend coming online play sounds on `/dev/dsp`
(`/usr/share/sounds/pingmsg`, made with `AgoraWav.chime`; `sounds=false` in
the account file turns them off). Send File in a conversation offers a file;
an offer shows Accept and Decline, and what is accepted lands in `~/Received
Files`. Rooms in the main window lists the chat rooms and joins one; each
room has a window with the talk and the people in it.

## Parley

The IRC client (`gui/apps/parley.gd`, package `parley`, on the desktop).

- **Connecting.** A form asks for the server, port, nickname and real name.
  The defaults come from `/etc/parley.conf` (irc.lanlink.net). Settings are
  saved to `~/.parley/parley.conf`, whose `join=` line lists channels to
  join on connect. `parley SERVER` connects straight away.
- **Tabs.** There is a Status tab, a tab per channel (the topic on top, the
  people on the right with ops first) and a tab per private conversation.
  Double-clicking a nick opens a private tab.
- **Typing.** A plain line talks to the open tab. The commands are /join,
  /part, /msg, /query, /me, /nick, /topic, /whois, /away, /list, /names,
  /kick, /op, /deop, /voice, /devoice, /quote, /clear and /quit.
- **Messages.** Joins, parts, quits, kicks, nick changes and modes are
  shown the way mIRC showed them. Parley answers CTCP VERSION, PING and
  TIME. A private message, or a line naming one's nick, makes the window
  blink when it is not in front.

## Checking the look

The headless tests can't render. To see screens, render under `xvfb-run` into
the root viewport and save PNGs (see [testing](../development/testing.md#screenshots)).
