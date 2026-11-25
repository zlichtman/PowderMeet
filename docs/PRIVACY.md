# Privacy

PowderMeet keeps only what its features need. No ads, no selling data, no tracking.

- **Account:** Sign in with Apple, or an email address and password, plus your name,
  photo, level and gear. Friends see these and your season totals. The camera and photo
  library are used only to set your profile photo.
- **Notifications:** your phone's push token is stored so the server can notify you; it
  is removed when you sign out or delete your account.
- **Location:** sent while a resort is open, seen only by friends you accept, for 15
  minutes, and deleted after 2 hours. It stops when you close the resort, move away
  from it or sign out.
- **Contacts:** only their email addresses are read, turned into hashes on
  your phone (the same address always gives the same hash, so anyone who already knows
  an address can work out its hash) and compared with the hash of each account's own email address to find
  friends. Only those hashes are sent to the server; names, numbers and the contacts
  themselves stay on your phone, and nothing is stored from them.
- **Imported runs:** kept with your account for your stats and pace. Friends never see
  the tracks.
- **Apple Health:** if you allow it, ski workouts and their routes are read (never
  written) to import your runs.
- **Usage:** a few app events, kept for 90 days.
- **Services:** Supabase hosts the data, Mapbox draws the map (turn off its anonymous
  usage data from the ⓘ on the map), and Apple handles sign-in and notifications.
- **Deleting your account** (Settings → Account) removes all of it.

Questions: [open an issue](https://github.com/zlichtman/PowderMeet/issues).
