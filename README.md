# 🚗 AutoCam - iPhone Xs Dash / Autobeveiliging Camera

AutoCam transformeert een oude iPhone Xs in een geavanceerde, slimme autobeveiligingscamera. De app draait **100% lokaal** met **Apple Vision AI** op de A12 Bionic chip.

---

## ✨ Functies

- 🎯 **Slimme Bewegingsdetectie in de Zone**: Reageert direct op elke betekenisvolle beweging binnen het getekende bewakingsvak om je auto.
- 🍃 **Intelligent Blaadjes- & Ruisfilter**: Dankzij ruimtelijke 2D-spreiding en drempelwaarde-analyse worden kleine voorbijvliegende blaadjes, dwarrelend stof of sensorruis genegeerd.
- 📸 **Directe Snapshot & HD Video**: Zodra er beweging in de zone is, maakt de app direct een foto en start onmiddellijk met het opnemen van een HD-videoclip (inclusief omgevingsaudio).
- 🧠 **Post-Exit AI Classificatie**: Pas nadat het object weer **uit beeld / uit de zone** is verdwenen, analyseert het lokale Apple Vision neurale netwerk wat het object was:
  - 👤 **Persoon**
  - 🚲 **Fietser**
  - 🚗 **Auto / Voertuig**
  - 📦 **Ander object / Overig**
- 📁 **Opslag in Aparte Mapjes**: Video's en foto's worden automatisch netjes gecategoriseerd opgeslagen in:
  - `Documents/Recordings/Personen/`
  - `Documents/Recordings/Fietsers/`
  - `Documents/Recordings/Autos/`
  - `Documents/Recordings/Overig/`
- 📲 **Aangepaste Telegram Meldingen**:
  - Directe foto-alert bij het begin van de beweging.
  - Volledige videoclip (MP4) na afloop, met het Telegram-bericht automatisch aangepast op het gedetecteerde type object (emoji, categorie en tijdsduur).
- 📂 **In-App Clips Galerij per Mapje**: Bekijk, speel direct af of beheer video's per categorie via de knop `📁 Clips`.
- 🌙 **OLED Stealth Modus**: Volledig zwart scherm met subtiele klok om batterij en warmte te besparen terwijl de bewaking op de achtergrond continu doorloopt.
- 🛡️ **TrollStore Compatibel**: Directe IPA-installatie via TrollStore op iOS 14 t/m 17.0 zonder 7-dagen limiet of revokes.

---

## 🚀 Installatie via TrollStore

1. Ga op je iPhone Xs (in Safari) naar de **[Releases](https://github.com/Deyksmits/Camera_xs/releases)** van deze repository.
2. Download het nieuwste bestand `AutoCam.ipa`.
3. Open het gedownloade bestand in **TrollStore** en tik op **Install**.
4. Open **AutoCam** vanaf je beginscherm.

---

## 🛠️ Gebruik

1. **Zone Instellen**:
   - Richt de iPhone Xs-camera op je auto.
   - Tik op **`✏️ Zone`** en tik op het scherm om een zone rondom je auto te tekenen.
   - Tik op **`✓ Klaar`** om de zone te activeren.
2. **Telegram Instellen (Optioneel)**:
   - Tik op **`⚙️ Setup`** en vul je Bot Token en Chat ID in.
3. **Bewaking Starten**:
   - Tik op **`▶ Start`**. De app bewaakt nu het vak.
4. **Video's Bekijken**:
   - Tik op **`📁 Clips`** om video's per mapje (`Personen`, `Fietsers`, `Auto's`, `Overig`) te bekijken en direct af te spelen.
