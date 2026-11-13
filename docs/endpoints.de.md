# Mär: Endpunkte

Zurück zur [README](../README.de.md) · [English](endpoints.md)

## Endpunkte

Genutzte Audiobookshelf-Endpunkte (vollständig, gemessen an `Sources/Networking/APIClient.swift`):

| Zweck | Endpunkt |
|---|---|
| Bibliotheken, eine Bibliothek | `GET /api/libraries`, `GET /api/libraries/{id}` |
| Buchliste (seitenweise) | `GET /api/libraries/{id}/items?minified=1&limit=&page=` |
| Regale Weiterhören / Zuletzt hinzugefügt | `GET /api/libraries/{id}/personalized` |
| Buchdetails, Kapitel und Fortschritt | `GET /api/items/{id}?expanded=1` |
| Fortschritt schreiben (Buch, Podcast-Folge) | `PATCH /api/me/progress/{itemId}`, `PATCH /api/me/progress/{itemId}/{episodeId}` |
| Fortschritt der ganzen Bibliothek | `GET /api/me` |
| Anmeldung mit Passwort | `POST /login` mit `x-return-tokens: true` |
| Anmeldewege, die der Server anbietet | `GET /status` |
| Einmalanmeldung (OpenID Connect, mit PKCE) | `GET /auth/openid?…&redirect_uri=audiobookshelf://oauth` im Anmeldefenster des Systems, danach `GET /auth/openid/callback?state=&code=&code_verifier=` |
| Suche (Bücher/Autoren/Serien) | `GET /api/libraries/{id}/search?q=` |
| Lesezeichen | `GET /api/me`, `POST /api/me/item/{id}/bookmark`, `DELETE /api/me/item/{id}/bookmark/{time}` |
| Cover, Autorenbild | `GET /api/items/{id}/cover?width=400&token=...` (Raster, Reihen, CarPlay, Widget), `GET /api/items/{id}/cover?raw=1&token=...` (Buchseite, großer Player, Sperrbildschirm), `GET /api/authors/{id}/image?token=...` |
| Podcast-Bibliotheken (zuschaltbare Quelle) | `POST /api/podcasts`, `POST /api/podcasts/feed`, `POST /api/podcasts/{id}/download-episodes` |
| Cover einer Sendung, Sendung entfernen (braucht Löschrechte) | `POST /api/items/{id}/cover`, `DELETE /api/items/{id}` |
| Hochladen einer lokalen Datei auf den Server | `POST /api/upload` |
| Audio-Stream | direkte `contentUrl` aus den Spurdaten; das Ende ihrer Umleitungen wird einmal mit `Range: bytes=0-0` gefragt, und der Kopf `Authorization: Bearer` geht nur an ein Ende auf dem Server selbst |

Genutzte gpodder/mygpo-Endpunkte (vollständig, `GPodderClient.swift`): `POST /api/2/auth/{user}/login.json`, `GET /api/2/devices/{user}.json` und `POST /api/2/devices/{user}/{device}.json` (die Geräte-Registrierung, die strengere Server verlangen), `GET/POST /api/2/subscriptions/{user}/{device}.json`, `GET/POST /api/2/episodes/{user}.json`.

Podcasts sprechen zusätzlich mit externen **RSS-Feeds**, der **PodcastIndex**-API und den **iTunes**-Charts (Entdecken/Metadaten, optionaler Schlüssel), deinem selbst gehosteten **gpodder/mygpo**-Server und dem `/sources/opml` einer **Pinchflat**-Instanz für ihre Kanalliste.

Musik spricht mit deinem **Subsonic/OpenSubsonic**-Server (vollständig, `SubsonicClient.swift`: `ping`, `getMusicFolders`, `getAlbumList2`, `getAlbum`, `getAlbumInfo2`, `getArtists`, `getArtist`, `getArtistInfo2`, `getTopSongs`, `getSong`, `getRandomSongs`, `getGenres`, `getSongsByGenre`, `getStarred2`, `search3`, `getPlaylists`, `getPlaylist`, `createPlaylist`, `updatePlaylist`, `deletePlaylist`, `getBookmarks`, `createBookmark`, `deleteBookmark`, `getLyricsBySongId`, `getScanStatus`, `stream`, `getCoverArt`, `scrobble`, `star`, `unstar`) oder deinem **Jellyfin**-Server (vollständig, `JellyfinClient.swift`: `Users/AuthenticateByName`, `Users/{id}/Views`, `Users/{id}/Items`, `Users/{id}/Items/{id}`, `Users/{id}/FavoriteItems/{id}`, `Users/{id}/PlayedItems/{id}`, `UserItems/{id}/UserData`, `Items/{id}/Images/Primary`, `Artists`, `MusicGenres`, `Audio/{id}/universal`, `Audio/{id}/Lyrics`, `Playlists`, `Playlists/{id}`, `Playlists/{id}/Items`, `Items/{id}`), dem **Cover Art Archive** (hochaufgelöste Cover über die MusicBrainz-ID) und **LRCLIB** (offener Rückfall für Songtexte).

Ein Mär-Sync-Dienst, wenn eingerichtet, wird erreicht über `GET /v2/key` (der Schlüssel des Dienstes), `POST /v1/session` (die versiegelte Sitzung, in der die anderen Anfragen reisen), `GET /v1/health`, `GET /v1/salt`, `POST /v1/password`, `POST /v1/token`, `GET`/`PUT /v1/doc/{kind}`, `GET /v1/docs/{kind}` und den Änderungs-Socket `/v1/changes`, alle beschrieben im eigenen Repository des Dienstes, [maer-sync](https://github.com/maer-lzs/maer-sync), dessen README eine Einrichtungsanleitung ist. **Die Leitung selbst ist auf beiden Seiten aufgeschrieben**: `docs/maer-sync-contract.md` hier und `CONTRACT.md` dort sind dieselbe Datei, und jedes Repository hält einen Zaun gegen seinen eigenen Code.

Radio nutzt den offenen Katalog **[Radio Browser](https://www.radio-browser.info/)** (`/json/stations/search`, Rückfall über die Spiegel `de1`/`at1`/`nl1`) und spielt deine eigenen Stream-URLs direkt; der laufende Song kommt aus den eigenen ICY-Metadaten des Streams.
