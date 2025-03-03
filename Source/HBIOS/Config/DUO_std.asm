;
;==================================================================================================
;   ROMWBW DEFAULT BUILD SETTINGS FOR DUODYNE
;==================================================================================================
;
; THIS FILE DEFINES THE DEFAULT CONFIGURATION SETTINGS FOR THE PLATFORM
; INDICATED ABOVE.  THESE SETTINGS DEFINE THE OFFICIAL BUILD FOR THIS
; PLATFORM AS DISTRIBUTED IN ROMWBW RELEASES.
;
; ROMWBW USES CASCADING CONFIGURATION FILES AS INDICATED BELOW:
;
; cfg_MASTER.asm			- MASTER: CONFIGURATION FILE DEFINES ALL POSSIBLE ROMWBW SETTINGS
; |
; +-> cfg_<platform>.asm		- PLATFORM: DEFAULT SETTINGS FOR SPECIFIC PLATFORM
;     |
;     +-> Config/<plt>_std.asm		- BUILD: SETTINGS FOR EACH OFFICIAL DIST BUILD
;         |
;         +-> Config/<plt>_<cust>.asm	- USER: CUSTOM USER BUILD SETTINGS
;
; THE TOP (MASTER CONFIGURATION) FILE DEFINES ALL POSSIBLE ROMWBW
; CONFIGURATION SETTINGS. EACH FILE BELOW THE MASTER CONFIGURATION FILE
; INHERITS THE CUMULATIVE SETTINGS OF THE FILES ABOVE IT AND MAY
; OVERRIDE THESE SETTINGS AS DESIRED.
;
; OTHER THAN THE TOP MASTER FILE, EACH FILE MUST "#INCLUDE" ITS PARENT
; FILE (SEE #INCLUDE STATEMENT BELOW).  THE TOP TWO FILES SHOULD NOT BE
; MODIFIED.
;
; TO CUSTOMIZE YOUR BUILD SETTINGS YOU SHOULD MODIFY THIS FILE, THE
; DEFAULT BUILD SETTINGS (Config/<platform>_std.asm) OR PREFERABLY
; CREATE AN OPTIONAL CUSTOM USER SETTINGS FILE THAT INCLUDES THE DEFAULT
; BUILD SETTINGS FILE (SEE EXAMPLE Config/SBC_user.asm).
;
; BY CREATING A CUSTOM USER SETTINGS FILE, YOU ARE LESS LIKELY TO BE
; IMPACTED BY FUTURE CHANGES BECAUSE YOU WILL BE INHERITING MOST
; OF YOUR SETTINGS WHICH WILL BE UPDATED BY AUTHORS AS ROMWBW EVOLVES.
;
; PLEASE REFER TO THE CUSTOM BUILD INSTRUCTIONS (README.TXT) IN THE
; SOURCE DIRECTORY (TWO DIRECTORIES ABOVE THIS ONE).
;
; *** WARNING: ASIDE FROM THE MASTER CONFIGURATION FILE, YOU MUST USE
; ".SET" TO OVERRIDE SETTINGS.  THE ASSEMBLER WILL ERROR IF YOU ATTEMPT
; TO USE ".EQU" BECAUSE IT WON'T LET YOU REDEFINE A SETTING WITH ".EQU".
;
#DEFINE	BOOT_DEFAULT	"H"		; DEFAULT BOOT LOADER CMD ON <CR> OR AUTO BOOT
;
#include "cfg_DUO.asm"
;
CPUOSC		.SET	8000000		; CPU OSC FREQ IN MHZ
CRTACT		.SET	FALSE		; ACTIVATE CRT (VDU,CVDU,PROPIO,ETC) AT STARTUP
;
INTMODE		.SET	2		; INTERRUPTS: 0=NONE, 1=MODE 1, 2=MODE 2, 3=MODE 3 (Z280)
;
DMAENABLE	.SET	TRUE		; DMA: ENABLE DMA DRIVER (DMA.ASM)
;
BATCOND		.SET	TRUE		; ENABLE LOW BATTERY WARNING MESSAGE
;
ROMSIZE		.SET	512		; SIZE OF ROM IN KB (MUST MATCH YOUR HARDWARE!!!)
RAMSIZE		.SET	512		; SIZE OF RAM IN KB (MUST MATCH YOUR HARDWARE!!!)
;
PCFENABLE	.SET	TRUE		; ENABLE PCF8584 I2C CONTROLLER
;
MDFFENABLE	.SET	FALSE		; MD: ENABLE FLASH FILE SYSTEM
;
UARTINTS	.SET	FALSE		; UART: INCLUDE INTERRUPT SUPPORT UNDER IM1/2/3
;
SN76489ENABLE	.SET	FALSE		; SN: ENABLE SN76489 SOUND DRIVER
;
CHENABLE	.SET	TRUE		; CH: ENABLE CH375/376 USB SUPPORT
;
ESPENABLE	.SET	FALSE 		; ESP: ENABLE ESP32 IO BOARD DRIVER (ESP.ASM)
