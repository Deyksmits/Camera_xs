# 🚗 AutoCam Suite - Slimme Beveiliging & Dashcam voor iPhone XS (TrollStore)

Deze repository bevat **twee volwaardige, gespecialiseerde iOS apps** ontworpen om een iPhone XS optimaal te benutten met TrollStore:

1. 🏎️ **SmartDash**: Standalone 30 FPS Dual-Cam Dashcam met Digitaal Cockpit Dashboard (Snelheid, Vision Bordherkenning, Flitsmeister-stijl Flitser Radar).
2. 🛡️ **AutoCam**: Ultra-duurzame Parkeerbewakingscamera met Apple Vision AI, geavanceerd nachtzicht en Telegram notificaties.

---

## 🏎️ SmartDash - Dual-Cam Dashcam & Cockpit HUD (`SmartDash.ipa`)

Speciaal ontwikkeld voor tijdens het autorijden. Geen afleidend camerabeeld op het scherm, maar een hypermodern digitaal automotive dashboard geïnspireerd door Porsche en Tesla:

- 📹 **Standaard 30 FPS Dual-Cam Opname**: Filmt gelijktijdig met de wegcamera (1080p @ 30 FPS) én de selfie/cabinecamera (720p @ 30 FPS) via `AVCaptureMultiCamSession` (hardwarematig op de A12 Bionic).
- 🚀 **Digital Cockpit HUD (Geen Camerabeeld op het Scherm)**:
  - ⚡ **Grote Digitale Snelheidsmeter**: Real-time GPS-snelheid in km/u met dynamische kleurwissel (wit/cyaan = veilig, oranje = limiet, pulserend rood = te snel).
  - 🛑 **Automatische Borddetectie (Apple Vision OCR)**: Detecteert Nederlandse RVV snelheidsborden (30, 50, 60, 70, 80, 100, 120, 130) en toont een realistisch rond snelheidsbord op het dashboard met subtiel audiosignaal.
  - 🚨 **Live Flitser & Trajectcontrole Radar (Flitsmeister / Waze stijl)**:
    - Offline database met alle bekende vaste flitspalen en trajectcontroles in Nederland (A1, A2, A4, A10, A12, A13, A16, A20, A58, provinciale wegen, stadsflitsers).
    - Waarschuwingskaart met dynamische afstandsbalk en pieptoon bij nadering binnen 750 meter.
    - Automatische online synchronisatie via OpenStreetMap Overpass API.
  - 🎯 **G-Kracht & Stabiliteitsmeter**: Real-time crosshair accelerometer visualisatie van bochten en remkracht (30 Hz).
  - 💥 **G-Sensor Botsingsbescherming**: Automatische detectie van noodstop of botsing (> 2.4G) met onmiddellijke vergrendeling van weg- en cabineclips.
  - 🔁 **Rolling Loop Buffer**: Continu opnemen in 3-minuten segmenten met automatische opslagrecycling tot 10 GB.
  - 📁 **In-App Galerij & Player**: Bekijk recente ritten en vergrendelde clips direct in de app, wissel tussen weg en cabine, of exporteer naar Foto's / AirDrop.
  - ⚡ **Auto-Start bij Contact**: Start automatisch met opnemen zodra de iPhone op de autolader wordt aangesloten.

---

## 🛡️ AutoCam - Parkeerbewaking (`AutoCam.ipa`)

Speciaal ontwikkeld voor wanneer de auto geparkeerd staat:

- 🔋 **Extreme Accubesparing (Zonder Stroom)**: Schakelt automatisch naar 3 FPS detectiemodus met 100% OLED pitch-black scherm binnen 4 seconden na ontkoppelen van de lader.
- 🎯 **Interactieve Bewakingszone**: Stel een 4-punts polygoon in rond de auto.
- 🌙 **Geavanceerd Nachtzicht**: Ruisloze monochrome modus met verhoogde schaduwdetails.
- 📲 **Telegram Notificaties & Web Remote**: 1 video per bewegingsincident met persoons-/autoclassificatie.

---

## 🚀 Installatie via TrollStore

1. Ga op je iPhone XS (in Safari) naar de **[Releases](https://github.com/Deyksmits/Camera_xs/releases)** van deze repository.
2. Download `SmartDash.ipa` en/of `AutoCam.ipa`.
3. Open het gedownloade bestand in **TrollStore** en tik op **Install**.
4. De apps staan nu direct op je beginscherm en kunnen naast elkaar gebruikt worden!
