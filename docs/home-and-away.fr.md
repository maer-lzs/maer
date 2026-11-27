# Un nom pour la maison et en déplacement

Mär reconnaît chaque serveur à son adresse. Une seconde adresse pour la maison en ferait un second serveur, avec sa propre connexion, ses téléchargements et ses positions d’écoute. Un seul nom qui atteint le serveur partout l’évite, et Mär n’a jamais à basculer.

## Trois façons

**DNS partagé (split DNS).** Votre routeur répond au nom public du serveur, à la maison, par son adresse locale ; ailleurs, le nom mène à l’adresse publique. Mär utilise le même nom aux deux endroits.

**Un VPN comme Tailscale ou WireGuard.** Le téléphone atteint votre réseau domestique depuis n’importe où, et vous saisissez l’adresse du serveur dans ce réseau.

**Un proxy inverse (reverse proxy).** Un nom public en https devant le serveur, joignable de l’extérieur ; beaucoup de routeurs renvoient aussi ce nom vers la maison depuis l’intérieur (souvent appelé NAT loopback ou hairpin NAT).

## Ce que vous saisissez dans Mär

Le nom unique, de préférence en https, pour que mots de passe et jetons ne circulent jamais en clair.
