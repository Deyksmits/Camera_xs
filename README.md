# ⚡ VibeCoded Apps - Slimme iOS Suite voor iPhone XS (TrollStore)

[![Build VibeCoded Apps](https://github.com/Deyksmits/Camera_xs/actions/workflows/build_ipa.yml/badge.svg)](https://github.com/Deyksmits/Camera_xs/actions/workflows/build_ipa.yml)
[![TrollStore Compatible](https://img.shields.io/badge/TrollStore-iOS%2014.0%20--%2017.0-blue.svg)](https://github.com/opa334/TrollStore)
[![Architecture](https://img.shields.io/badge/Architecture-ARM64-orange.svg)](#)

Deze repository bevat **vier volwaardige, gespecialiseerde standalone iOS apps** om een iPhone XS (of ander toestel met TrollStore) optimaal te benutten:

1. 🏎️ **SmartDash (`SmartDash.ipa`)**: Cockpit HUD & Dual-Cam Dashcam met Flitsmeister flitsers, acceleratiemeting en G-Force meter.
2. 🛡️ **AutoCam (`AutoCam.ipa`)**: Professionele CCTV parkeerbewaking met extreme accubesparing, nachtzicht, Telegram meldingen en Web Remote (poort 8081).
3. 🌐 **NetShield (`NetShield.ipa`)**: 24/7 Thuisnetwerk DNS AdBlocker (Pi-hole alternatief) met root poort 53 daemon en ingebouwd Web Dashboard (poort 8080).
4. 🏠 **HomeSentry (`HomeSentry.ipa`)**: 24/7 Trap & Voordeur AI Beveiliging met akoestisch glasbreuk-, rookdetector- en waterlek-alarm, temperatuur, barometer en Web Dashboard (poort 8082).

---

## 🏎️ 1. SmartDash - Dual-Cam Dashcam & Cockpit HUD (`SmartDash.ipa`)

Speciaal ontworpen voor tijdens het autorijden. Geen afleidend camerabeeld, maar een hypermodern automotive dashboard:
- 🧭 **Centrale Digitale Snelheidsmeter**: In landscape modus staat de snelheid prominent en haarscherp exact in het midden van het scherm.
- 🚨 **Flitsmeister-Stijl Notificaties (Links)**: Offline database van alle vaste flitspalen en trajectcontroles in Nederland met afstandsteller en max. snelheid bord.
- ⚡ **Intelligente Acceleratie-Meting (Links)**: Meet snelle optrekacties vanuit stilstand naar het afgeronde tiental (bijv. 0 naar 78 km/u -> berekent tijd naar 70 km/u) met compact scorebord.
- 🎯 **G-Kracht Meter & Opnametimer (Rechts)**: Realtime 30 Hz telemetrie dial en compacte segmenttimer.
- ⚙️ **Overzichtelijk Instellingenblad**: Alle extra functies (zoals voorruit HUD spiegelmodus, clipgalerij, telemetrie reset) netjes weggestopt in een handig instellingentabblad.
- 📹 **30 FPS Dual-Cam Opname**: Filmt gelijktijdig de weg (1080p) en het interieur (720p) met automatische rolling loop buffer.

---

## 🛡️ 2. AutoCam - Pure Parkeerbewaking (`AutoCam.ipa`)

Speciaal ontworpen voor wanneer de auto geparkeerd staat. 100% gefocust op surveillance met de look en feel van een professioneel camerasysteem:
- 🏢 **Professionele CCTV Surveillance UI**: Industriële bewakingsinterface (UniFi Protect / Axis stijl) met live timecode en viewfinder reticles.
- 🍃 **Slimme AI Ruis- & Reflectie-Filter**: Filtert omgevingsbewegingen zoals wiegende bomen, dwarrelende bladeren en wapperende gordijnen/raamreflecties automatisch weg via adaptieve oscillatie-analyse en Apple Neural Engine multi-frame verificatie.
- 🔋 **Extreme Accubesparing (Zonder Stroom)**: Schakelt automatisch naar 3 FPS detectie met 100% OLED pitch-black scherm binnen 4 seconden na ontkoppelen van de lader.
- 🌙 **Geavanceerd Nachtzicht**: Monochrome modus met verhoogde schaduwdetails.
- 📲 **Telegram Notificaties & Web Remote (Poort 8081)**: Live camera stream, bewakingszone aanpassen en status uitlezen via browser op `http://<iphone-ip>:8081/?key=<PIN>`.

---

## 🌐 3. NetShield - 24/7 Thuisnetwerk DNS AdBlocker (`NetShield.ipa`)

Maakt van je iPhone een 24/7 advertentie- en tracker-blokkerend schild voor alle apparaten in huis (Pi-hole alternatief):
- 🛑 **Poort 53 Root DNS Daemon**: Luistert lokaal naar UDP poort 53 (dankzij TrollStore sandbox bypass) en blokkeert advertenties met `0.0.0.0`.
- 🌐 **Ingebouwd Web Dashboard (Poort 8080)**: Beheer statistieken en bekijk live DNS-verzoeken via `http://<iphone-ip>:8080/`.
- ⚡ **Ultra-Snelle In-Memory Cache**: Schone domeinen worden doorgestuurd naar Cloudflare (`1.1.1.1`) of Quad9 (`9.9.9.9`) en lokaal gecached.
- 🔋 **24/7 Background Keepalive**: Inclusief background audio loop zodat iOS de app nooit afsluit wanneer het scherm uit staat aan de lader.
- 📖 **In-App Router Stappenplan**: Complete handleiding voor Ziggo, KPN, Odido, Fritz!Box en TP-Link.

---

## 🏠 4. HomeSentry - Trap & Voordeur AI Beveiliging (`HomeSentry.ipa`)

Speciaal ontworpen om je iPhone XS boven bij de trap neer te zetten, permanent gericht op de hal en de voordeur beneden:
- 🚪 **Trap-naar-Voordeur AI Bewakingszone**: Bepaal met 4 sleepbare hoeken de perimeter van je voordeur; intelligente detectie filtert ganglichten en schaduwen weg.
- 🔊 **24/7 Akoestische Sensor AI (Apple SoundAnalysis)**:
  - 🚨 **Glasbreuk Detectie**: Slaat alarm bij inslaan of breken van ruiten in de hal.
  - 🔥 **3.1 kHz Rookmelder & Brandalarm Detectie**: Herkent de indringende pieptoon van standaard rookmelders en CO-melders.
  - 💧 **Waterlekkage & Druppels**: Detecteert lekkend leidingwater of druppelende kranen/radiatoren.
- 🌡️ **Klimaat & Barometer Telemetrie**:
  - Realtime kamertemperatuur (°C) met min/max daghistorie.
  - Hoge-precisie luchtdruk (`hPa`) en luchtdruktrend.
  - **Voordeur Tocht-Detectie**: Zodra de voordeur beneden opengaat, detecteert de barometer direct de resulterende drukgolf in het trapgat!
- 🌐 **Ingebouwd Web Dashboard (Poort 8082)**: Live meekijken, video's downloaden en sensoren monitoren via `http://<iphone-ip>:8082/?key=<PIN>`.
- 📲 **Telegram Spoed Alarm & Afstandsbediening**: Stuurt direct video bij personen/pakketjes aan de deur én spoedmeldingen bij glasbreuk of brandalarm.
- 🕶️ **OLED Pitch-Black Stealth**: Scherm schakelt automatisch naar 0% zwart zodat de telefoon 's nachts onzichtbaar op de trap staat.

---

## 📲 Installatie via TrollStore

1. Ga op je iPhone XS (in Safari) naar de **[Releases](https://github.com/Deyksmits/Camera_xs/releases)** van deze repository.
2. Download de gewenste `.ipa` (`HomeSentry.ipa`, `SmartDash.ipa`, `AutoCam.ipa` en/of `NetShield.ipa`).
3. Open het gedownloade bestand in **TrollStore** en tik op **Install**.
4. De apps staan nu direct op je beginscherm en kunnen naast elkaar gebruikt worden!
