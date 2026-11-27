# Ein Name für zu Hause und unterwegs

Mär erkennt jeden Server an seiner Adresse. Eine zweite Adresse für zu Hause machte ihn zu einem zweiten Server, mit eigener Anmeldung, eigenen Downloads und Hörständen. Ein Name, der den Server überall erreicht, vermeidet das, und Mär muss nie umschalten.

## Drei Wege

**Split DNS.** Dein Router beantwortet den öffentlichen Namen des Servers zu Hause mit seiner Adresse im Heimnetz; überall sonst führt der Name zur öffentlichen Adresse. Mär nutzt an beiden Orten denselben Namen.

**Ein VPN wie Tailscale oder WireGuard.** Das Telefon erreicht dein Heimnetz von überall, und du trägst die Adresse des Servers in diesem Netz ein.

**Ein Reverse Proxy.** Ein öffentlicher Name mit https vor dem Server, von außen erreichbar; viele Router führen diesen Namen auch von drinnen zurück ins Heimnetz (oft NAT Loopback oder Hairpin NAT genannt).

## Was du in Mär einträgst

Den einen Namen, am besten mit https, damit Passwörter und Zugangszeichen nie im Klartext reisen.
