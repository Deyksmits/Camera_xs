# 🚗 AutoCam - iPhone Xs Dash / Autobeveiliging Camera

AutoCam transformeert een oude iPhone Xs in een geavanceerde, slimme autobeveiligingscamera. De app draait **100% lokaal** met **Apple Vision AI** op de A12 Bionic chip en detecteert automatisch wanneer een persoon te dicht bij je geparkeerde auto komt.

---

## ✨ Functies

- 🚶‍♂️ **Apple Vision AI Mensendetectie**: Real-time detectie van personen via de A12 Neural Engine zonder internetvertraging.
- 📐 **Instelbare Auto Bewakingszone**: Teken met je vinger eenvoudig een zone op het scherm rond je geparkeerde auto.
- 📏 **Proximity / Afstandsdetectie**: Detecteert niet alleen personen binnen de zone, maar berekent ook wiskundig of iemand zich dicht bij de rand van de auto bevindt (bufferbereik).
- 🎥 **Automatische Video-Opname**: Zodra een persoon dichtbij je auto komt, start de app direct met het opnemen van een HD-videoclip (inclusief omgevingsgeluid). De opname blijft doorlopen zolang er activiteit rondom de auto is.
- 💾 **Lokale Opslag & iOS Bestanden**: Video's worden veilig opgeslagen in `Bestanden/AutoCam/Recordings` en toegevoegd aan je iOS Foto's / Camera Roll.
- 📁 **In-App Clips Galerij**: Bekijk, speel direct af of verwijder opnames via de knop `📁 Clips`.
- 📲 **Telegram Notificaties & Video's**:
  - Directe foto-alert bij detectie (binnen 1 seconde).
  - Volledige bewakingsvideoclip (MP4) wordt na afronding automatisch verstuurd naar je Telegram chat.
- 🌙 **OLED Stealth Modus**: Schakelt het scherm uit (zwart OLED scherm met subtiele klok) om stroom en warmte te besparen, terwijl de bewaking en video-opname op de achtergrond actief blijven.
- 🛡️ **TrollStore Compatibel**: Directe IPA-installatie via TrollStore op iOS 14 t/m 17.0 zonder app herondertekening (geen 7-dagen limiet).

---

## 🚀 Installatie via TrollStore

1. Ga op je iPhone Xs (in Safari) naar de **[Releases](https://github.com/Deyksmits/Camera_xs/releases)** van deze repository.
2. Download het bestand `AutoCam.ipa`.
3. Open het gedownloade bestand in **TrollStore** en tik op **Install**.
4. Open **AutoCam** vanaf je beginscherm.

---

## 🛠️ Gebruik

1. **Zone Instellen**:
   - Richt de camera van de iPhone Xs door het raam op je auto.
   - Tik op **`✏️ Zone`** en tik op het scherm op de hoekpunten rondom je auto.
   - Tik op **`✓ Klaar`** om de zone op te slaan.
2. **Telegram Instellen (Optioneel)**:
   - Tik op **`⚙️ Setup`**.
   - Vul je Telegram Bot Token en Chat ID in om meldingen en videoclips op je eigen telefoon te ontvangen.
3. **Bewaking Starten**:
   - Tik op **`▶ Start`**. De knop verandert in `⏸ Stop` en de statusbalk toont `● BEWAKING ACTIEF`.
4. **Stealth Modus**:
   - Tik op **`🌙 Zwart`** voor een donker OLED scherm. Tik op het scherm om weer terug te keren naar de live preview.
5. **Video's Bekijken**:
   - Tik op **`📁 Clips`** om opgeslagen incidentvideo's direct te bekijken of te wissen.
   - Of open de standaard **Bestanden** (Files) app van iOS of de **Foto's** app.

---

## 🔄 Automatische IPA Build (GitHub Actions)

Elke push naar de `main` branch start automatisch de GitHub Actions workflow:
- Compileert de native Swift arm64 binary.
- Zorgt voor uitvoerbaarheid (`chmod +x`) en `CFBundleExecutable`.
- Past ad-hoc codesigning toe.
- Genereert de kant-en-klare `.ipa` en publiceert deze in GitHub Releases.
