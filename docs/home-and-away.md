# A name for home and away

Mär knows each server by its address. A second address for home would make it a second server, with its own sign in, downloads and listening positions. One name that reaches the server everywhere avoids that, and Mär never has to switch.

## Three ways

**Split DNS.** Your router answers the server's public name with its address at home; everywhere else the name leads to the public address. Mär uses the same name in both places.

**A VPN such as Tailscale or WireGuard.** The phone reaches your home network from anywhere, and you enter the server's address in that network.

**A reverse proxy.** One public name with https in front of the server, reachable from outside; many routers also lead that name back home from inside (often called hairpin NAT or NAT loopback).

## What you enter in Mär

The one name, preferably with https, so passwords and tokens never travel in plain text.
