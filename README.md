## Raspberry Pi Node-RED Bulb & Fan Controller

------------------------------
## Core Features

* Web UI Only: Two independent latching switches on the Node-RED Dashboard, one for Bulb and one for Fan. No physical button.
* No Auto-Off: Outputs stay ON until manually switched OFF. No countdown timer.
* Live Status Dashboard: Displays current Bulb Status (ON/OFF) and Fan Status (ON/OFF).
* Native OS Execution: Controls hardware directly through `pinctrl` system commands via `exec` nodes.

Flow logic per device: `ui-switch` (ON/OFF, `passthru: false`, `decouple: true`) -> `function` Controller (fans out to GPIO command, switch sync `true`/`false`, status text ON/OFF) -> `function` Build pinctrl Command -> `exec` node.

Commands used:

* Bulb ON: `pinctrl set 23 op dl` / Bulb OFF: `pinctrl set 23 ip pu`
* Fan ON: `pinctrl set 24 op dl` / Fan OFF: `pinctrl set 24 ip pu`

------------------------------
## Hardware Configuration & Wiring
Connect the components to the Raspberry Pi 40-pin GPIO header using the physical pin locations listed below.

| Device Component | Connection Target | Raspberry Pi Header Location | Function |
| :--- | :--- | :--- | :--- |
| **Main Ground Wire** | Breadboard Blue Rail (-) | Top row, 3rd pin from left (Pin 6) | Supplies Ground (0V) to the breadboard rail |
| **Main 5V Power Wire** | Breadboard Red Rail (+) | Top row, 1st pin from left (Pin 2) | Supplies 5V Power to the breadboard rail |
| **Bulb Relay VCC** | Breadboard Red Rail (+) | None (Powered via Red Rail) | 5V Power for bulb relay channel |
| **Bulb Relay GND** | Breadboard Blue Rail (-) | None (GND via Blue Rail) | Circuit Ground |
| **Bulb Relay IN** | Physical Pin 16 (GPIO 23) | Top row, 8th pin from left | Latching control signal for Bulb |
| **Fan Relay VCC** | Breadboard Red Rail (+) | None (Powered via Red Rail) | 5V Power for fan relay channel |
| **Fan Relay GND** | Breadboard Blue Rail (-) | None (GND via Blue Rail) | Circuit Ground |
| **Fan Relay IN** | Physical Pin 18 (GPIO 24) | Top row, 9th pin from left | Latching control signal for Fan |

------------------------------
## Dependencies
All of these are installed automatically by `setup.sh`:

* @flowfuse/node-red-dashboard (v1.31.0 or higher)
* Node-RED (global npm install, Node.js 20 LTS via NodeSource if needed)
* System packages: `curl git python3 raspi-utils ca-certificates gnupg` (`raspi-utils` provides `pinctrl`)

Ensure the host OS provides the `pinctrl` CLI utility (used by the `exec` nodes for GPIO 23 and GPIO 24).

No `rpi-gpio` nodes are used in this flow.

------------------------------
## Installation and Deployment
## 1. Run Automated Setup (installs Node-RED + requirements + hardware test)

####   sudo chmod +x setup.sh
   
####   sudo ./setup.sh               
   
####   sudo./setup.sh --skip-test    

   What it does:
   1. `apt-get update` + installs system packages and verifies `pinctrl`.
   2. Installs Node.js 20 LTS (if missing/old), Node-RED globally, and Dashboard 1.31.0 in `~/.node-red`.
   3. Beginner hardware test: for Bulb (GPIO 23) then Fan (GPIO 24), it asks you to confirm relay IN wiring, turns ON with `pinctrl set <gpio> op dl`, asks `Did it turn ON? [y/N]`, then turns OFF with `pinctrl set <gpio> ip pu` and asks `Did it turn OFF?`. Reports PASS / FAIL / SKIPPED and leaves pins in safe OFF state.

## 2. Import the JSON Flow

   1. Open your Node-RED instance in a web browser.
   2. Open the menu in the top right corner and select Import.
   3. Import the raw JSON array string provided in your source configuration file.
   4. Click Import.

## 3. Deploy and Access

   1. Click the Deploy button in the top right corner of the Node-RED editor.
   2. Access the user control panel at the dedicated endpoint url:

    http://<YOUR_PI_IP_ADDRESS>:1880/dashboard/home

Dashboard layout: `Control Panel` group contains the Bulb and Fan switches. `Status` group contains Bulb Status and Fan Status texts.
