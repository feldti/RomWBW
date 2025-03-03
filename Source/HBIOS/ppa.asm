;
;=============================================================================
;   PPA DISK DRIVER
;=============================================================================
;
; PARALLEL PORT INTERFACE FOR SCSI DISK DEVICES USING A PARALLEL PORT
; ADAPTER.  PRIMARILY TARGETS PARALLEL PORT IOMEGA ZIP DRIVES.
;
; INTENDED TO CO-EXIST WITH LPT DRIVER.
;
; CREATED BY WAYNE WARTHEN FOR ROMWBW HBIOS.
; MUCH OF THE CODE IS DERIVED FROM LINUX AND FUZIX (ALAN COX).
; - https://github.com/EtchedPixels/FUZIX
; - https://github.com/torvalds/linux
;
; 05/23/2023 WBW - INITIAL RELEASE
; 05/26/3023 WBW - CLEAN UP, LED ACTIVITY
; 05/27/2023 WBW - ADDED SPP MODE
; 06/06/2023 WBW - OPTIMIZE BLOCK READ AND WRITE
;
;=============================================================================
;
;  IBM PC STANDARD PARALLEL PORT (SPP):
;  - NHYODYNE PRINT MODULE
;
;  PORT 0 (OUTPUT):
;
;	D7	D6	D5	D4	D3	D2	D1	D0
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;     | PD7   | PD6   | PD5   | PD4   | PD3   | PD2   | PD1   | PD0   |
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;
;  PORT 1 (INPUT):
;
;	D7	D6	D5	D4	D3	D2	D1	D0
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;     | /BUSY | /ACK  | POUT  | SEL   | /ERR  | 0     | 0     | 0     |
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;
;  PORT 2 (OUTPUT):
;
;	D7	D6	D5	D4	D3	D2	D1	D0
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;     | STAT1 | STAT0 | ENBL  | PINT  | SEL   | RES   | LF    | STB   |
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;
;=============================================================================
;
;  MG014 STYLE INTERFACE:
;  - RCBUS MG014 MODULE
;
;  PORT 0 (OUTPUT):
;
;	D7	D6	D5	D4	D3	D2	D1	D0
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;     | PD7   | PD6   | PD5   | PD4   | PD3   | PD2   | PD1   | PD0   |
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;
;  PORT 1 (INPUT):
;
;	D7	D6	D5	D4	D3	D2	D1	D0
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;     |	      |	      |	      | /ERR  | SEL   | POUT  | BUSY  | /ACK  |
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;
;  PORT 2 (OUTPUT):
;
;	D7	D6	D5	D4	D3	D2	D1	D0
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;     | LED   |	      |	      |	      | /SEL  | /RES  | /LF   | /STB  |
;     +-------+-------+-------+-------+-------+-------+-------+-------+
;
;=============================================================================
;
; TODO:
;
; NOTES:
;
; - THIS DRIVER IS FOR THE ZIP DRIVE PPA INTERFACE.  IT WILL SIMPLY
;   FAIL TO EVEN RECOGNIZE A ZIP DRIVE WITH THE NEWER IMM INTERFACE.
;   THERE DOES NOT SEEM TO BE A WAY TO VISUALLY DETERMINE IF A ZIP
;   DRIVE IS PPA OR IMM.  SIGH.
;
; - THIS DRIVER OPERATES USES NIBBLE READ MODE.  ALTHOUGH THE 8255
;   (MG014) CAN READ OR WRITE TO PORT A (DATA), IT "GLITCHES" WHEN
;   THE MODE IS CHANGED CAUSING THE CONTROL LINES TO CHANGE AND
;   BREAKS THE PROTOCOL.  I SUSPECT THE MBC SPP CAN SUPPORT FULL BYTE
;   MODE, (PS2 STYLE), BUT I HAVE NOT ATTEMPTED IT.
;
; - RELATIVE TO ABOVE, THIS BEAST IS SLOW.  IN ADDITION TO THE
;   NIBBLE MODE READS, THE MG014 ASSIGNS SIGNALS DIFFERENTLY THAN
;   THE STANDARD IBM PARALLEL PORT WHICH NECESSITATES A BUNCH OF EXTRA
;   BIT FIDDLING ON EVERY READ.
;
; - SOME OF THE DATA TRANSFERS HAVE NO BUFFER OVERRUN CHECKS.  IT IS
;   ASSUMED SCSI DEVICES WILL SEND/REQUEST THE EXPECTED NUMBER OF BYTES.
;
; PPA PORT OFFSETS
;
PPA_IODATA	.EQU	0		; PORT A, DATA, OUT
PPA_IOSTAT	.EQU	1		; PORT B, STATUS, IN
PPA_IOCTRL	.EQU	2		; PORT C, CTRL, OUT
PPA_IOSETUP	.EQU	3		; PPI SETUP
;
; SCSI UNIT IDS
;
PPA_SELF	.EQU	7
PPA_TGT		.EQU	6
;
; PPA DEVICE STATUS
;
PPA_STOK	.EQU	0
PPA_STNOMEDIA	.EQU	-1
PPA_STCMDERR	.EQU	-2
PPA_STIOERR	.EQU	-3
PPA_STTO	.EQU	-4
PPA_STNOTSUP	.EQU	-5
;
; PPA DEVICE CONFIGURATION
;
PPA_CFGSIZ	.EQU	12		; SIZE OF CFG TBL ENTRIES
;
; PER DEVICE DATA OFFSETS IN CONFIG TABLE ENTRIES
;
PPA_DEV		.EQU	0		; OFFSET OF DEVICE NUMBER (BYTE)
PPA_MODE	.EQU	1		; OPERATION MODE: PPA MODE (BYTE)
PPA_STAT	.EQU	2		; LAST STATUS (BYTE)
PPA_IOBASE	.EQU	3		; IO BASE ADDRESS (BYTE)
PPA_MEDCAP	.EQU	4		; MEDIA CAPACITY (DWORD)
PPA_LBA		.EQU	8		; OFFSET OF LBA (DWORD)
;
; MACROS
;
#DEFINE PPA_WCTL(VAL)	LD A,VAL \ CALL PPA_WRITECTRL
#DEFINE PPA_WDATA(VAL)	LD A,VAL \ CALL PPA_WRITEDATA
;
#DEFINE PPA_DPUL(VAL)	LD A,VAL \ CALL PPA_DPULSE
#DEFINE PPA_CPUL(VAL)	LD A,VAL \ CALL PPA_CPULSE
;
; INCLUDE MG014 NIBBLE MAP FOR MG014 MODE
;
#IF (PPAMODE == IMMMODE_MG014)
  #DEFINE MG014_MAP
#ENDIF
;
;=============================================================================
; INITIALIZATION ENTRY POINT
;=============================================================================
;
PPA_INIT:
	LD	IY,PPA_CFG		; POINT TO START OF CONFIG TABLE
;
PPA_INIT1:
	LD	A,(IY)			; LOAD FIRST BYTE TO CHECK FOR END
	CP	$FF			; CHECK FOR END OF TABLE VALUE
	JR	NZ,PPA_INIT2		; IF NOT END OF TABLE, CONTINUE
	XOR	A			; SIGNAL SUCCESS
	RET				; AND RETURN
;
PPA_INIT2:
	CALL	NEWLINE			; FORMATTING
	PRTS("PPA:$")			; DRIVER LABEL
;
	PRTS(" IO=0x$")			; LABEL FOR IO ADDRESS
	LD	A,(IY+PPA_IOBASE)	; GET IO BASE ADDRES
	CALL	PRTHEXBYTE		; DISPLAY IT
;
	PRTS(" MODE=$")			; LABEL FOR MODE
	LD	A,(IY+PPA_MODE)		; GET MODE BITS

	LD	HL,PPA_STR_MODE_MAP
	ADD	A,A
	CALL	ADDHLA
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	CALL	WRITESTR
;
	; CHECK FOR HARDWARE PRESENCE
	CALL	PPA_DETECT		; PROBE FOR INTERFACE
	JR	Z,PPA_INIT4		; IF FOUND, CONTINUE
	CALL	PC_SPACE		; FORMATTING
	LD	DE,PPA_STR_NOHW		; NO PPA MESSAGE
	CALL	WRITESTR		; DISPLAY IT
	JR	PPA_INIT6		; SKIP CFG ENTRY
;
PPA_INIT4:
	; UPDATE DRIVER RELATIVE UNIT NUMBER IN CONFIG TABLE
	LD	A,(PPA_DEVNUM)		; GET NEXT UNIT NUM TO ASSIGN
	LD	(IY+PPA_DEV),A		; UPDATE IT
	INC	A			; BUMP TO NEXT UNIT NUM TO ASSIGN
	LD	(PPA_DEVNUM),A		; SAVE IT
;
	; ADD UNIT TO GLOBAL DISK UNIT TABLE
	LD	BC,PPA_FNTBL		; BC := FUNC TABLE ADR
	PUSH	IY			; CFG ENTRY POINTER
	POP	DE			; COPY TO DE
	CALL	DIO_ADDENT		; ADD ENTRY TO GLOBAL DISK DEV TABLE
;
	CALL	PPA_RESET		; RESET/INIT THE INTERFACE
#IF (PPATRACE <= 1)
	CALL	NZ,PPA_PRTSTAT
#ENDIF
	JR	NZ,PPA_INIT6
;
	; START PRINTING DEVICE INFO
	CALL	PPA_PRTPREFIX		; PRINT DEVICE PREFIX
;
PPA_INIT5:
	; PRINT STORAGE CAPACITY (BLOCK COUNT)
	PRTS(" BLOCKS=0x$")		; PRINT FIELD LABEL
	LD	A,PPA_MEDCAP		; OFFSET TO CAPACITY FIELD
	CALL	LDHLIYA			; HL := IY + A, REG A TRASHED
	CALL	LD32			; GET THE CAPACITY VALUE
	CALL	PRTHEX32		; PRINT HEX VALUE
;
	; PRINT STORAGE SIZE IN MB
	PRTS(" SIZE=$")			; PRINT FIELD LABEL
	LD	B,11			; 11 BIT SHIFT TO CONVERT BLOCKS --> MB
	CALL	SRL32			; RIGHT SHIFT
	CALL	PRTDEC32		; PRINT DWORD IN DECIMAL
	PRTS("MB$")			; PRINT SUFFIX
;
PPA_INIT6:
	LD	DE,PPA_CFGSIZ		; SIZE OF CFG TABLE ENTRY
	ADD	IY,DE			; BUMP POINTER
	JP	PPA_INIT1		; AND LOOP
;
;----------------------------------------------------------------------
; PROBE FOR PPA HARDWARE
;----------------------------------------------------------------------
;
; ON RETURN, ZF SET INDICATES HARDWARE FOUND
;
PPA_DETECT:
#IF (PPATRACE >= 3)
	PRTS("\r\nDETECT:$")
#ENDIF
;
#IF (PPAMODE == PPAMODE_MG014)
	; INITIALIZE 8255
	LD	A,(IY+PPA_IOBASE)	; BASE PORT
	ADD	A,PPA_IOSETUP		; BUMP TO SETUP PORT
	LD	C,A			; MOVE TO C FOR I/O
	LD	A,$82			; CONFIG A OUT, B IN, C OUT
	OUT	(C),A			; DO IT
	CALL	DELAY			; BRIEF DELAY FOR GOOD MEASURE
#ENDIF
;
	PPA_WDATA($AA)
	CALL	PPA_DISCONNECT
	CALL	PPA_CONNECT
	PPA_WCTL($0E)
	CALL	PPA_READSTATUS
;
#IF (PPATRACE >= 3)
	CALL	PC_SPACE
	CALL	PRTHEXBYTE
#ENDIF
;
	AND	$08
	CP	$08
	JR	NZ,PPA_DETECT_FAIL
;
	PPA_WCTL($0C)
	CALL	PPA_READSTATUS
;
#IF (PPATRACE >= 3)
	CALL	PC_SPACE
	CALL	PRTHEXBYTE
#ENDIF
;
	AND	$08
	CP	$00
	JR	NZ,PPA_DETECT_FAIL
;
	CALL	PPA_DISCONNECT
;
	PPA_WDATA($AA)
	PPA_WCTL($0C)
;
	XOR	A			; SIGNAL SUCCESS
	RET				; AND RETURN
;
PPA_DETECT_FAIL:
	OR	$FF			; SIGNAL FAILURE
	RET	NZ
;
;=============================================================================
; DRIVER FUNCTION TABLE
;=============================================================================
;
PPA_FNTBL:
	.DW	PPA_STATUS
	.DW	PPA_RESET
	.DW	PPA_SEEK
	.DW	PPA_READ
	.DW	PPA_WRITE
	.DW	PPA_VERIFY
	.DW	PPA_FORMAT
	.DW	PPA_DEVICE
	.DW	PPA_MEDIA
	.DW	PPA_DEFMED
	.DW	PPA_CAP
	.DW	PPA_GEOM
#IF (($ - PPA_FNTBL) != (DIO_FNCNT * 2))
	.ECHO	"*** INVALID PPA FUNCTION TABLE ***\n"
#ENDIF
;
PPA_VERIFY:
PPA_FORMAT:
PPA_DEFMED:
	SYSCHKERR(ERR_NOTIMPL)		; NOT IMPLEMENTED
	RET
;
;
;
PPA_READ:
	CALL	HB_DSKREAD		; HOOK DISK READ CONTROLLER
	LD	A,SCSI_CMD_READ		; SETUP SCSI READ
	LD	(PPA_CMD_RW),A		; AND SAVE IT IN SCSI CMD
	JP	PPA_IO			; DO THE I/O
;
;
;
PPA_WRITE:
	CALL	HB_DSKWRITE		; HOOK DISK WRITE CONTROLLER
	LD	A,SCSI_CMD_WRITE	; SETUP SCSI WRITE
	LD	(PPA_CMD_RW),A		; AND SAVE IT IN SCSI CMD
	JP	PPA_IO			; DO THE I/O
;
;
;
PPA_IO:
	PUSH	HL
	CALL	PPA_CHKERR		; CHECK FOR ERR STATUS AND RESET IF SO
	POP	HL
	JR	NZ,PPA_IO3		; BAIL OUT ON ERROR
;
	LD	(PPA_DSKBUF),HL		; SAVE DISK BUFFER ADDRESS
;
;;;#IF (DSKYENABLE)
;;;  #IF (DSKYDSKACT)
	LD	A,PPA_LBA
	CALL	LDHLIYA
	CALL	HB_DSKACT		; SHOW ACTIVITY
;;;  #ENDIF
;;;#ENDIF
;
	; SETUP LBA
	; 3 BYTES, LITTLE ENDIAN -> BIG ENDIAN
	LD	HL,PPA_CMD_RW+1		; START OF LBA FIELD IN CDB (MSB)
	LD	A,(IY+PPA_LBA+2)	; THIRD BYTE OF LBA FIELD IN CFG (MSB)
	LD	(HL),A
	INC	HL
	LD	A,(IY+PPA_LBA+1)
	LD	(HL),A
	INC	HL
	LD	A,(IY+PPA_LBA+0)
	LD	(HL),A
	INC	HL
;
	; DO SCSI IO
	LD	DE,(PPA_DSKBUF)		; DISK BUFFER TO DE
	LD	A,1			; BLOCK I/O, ONE SECTOR
	LD	HL,PPA_CMD_RW		; POINT TO READ/WRITE CMD TEMPLATE
	CALL	PPA_RUNCMD		; RUN THE SCSI ENGINE
	CALL	Z,PPA_CHKCMD		; IF EXIT OK, CHECK SCSI RESULTS
	JR	NZ,PPA_IO2		; IF ERROR, SKIP INCREMENT
	; INCREMENT LBA
	LD	A,PPA_LBA		; LBA OFFSET
	CALL	LDHLIYA			; HL := IY + A, REG A TRASHED
	CALL	INC32HL			; INCREMENT THE VALUE
	; INCREMENT DMA
	LD	HL,PPA_DSKBUF+1		; POINT TO MSB OF BUFFER ADR
	INC	(HL)			; BUMP DMA BY
	INC	(HL)			; ... 512 BYTES
	XOR	A			; SIGNAL SUCCESS
;
PPA_IO2:
PPA_IO3:
	LD	HL,(PPA_DSKBUF)		; CURRENT DMA TO HL
	OR	A			; SET FLAGS BASED ON RETURN CODE
	RET	Z			; RETURN IF SUCCESS
	LD	A,ERR_IO		; SIGNAL IO ERROR
	OR	A			; SET FLAGS
	RET				; AND DONE
;
;
;
PPA_STATUS:
	; RETURN UNIT STATUS
	LD	A,(IY+PPA_STAT)		; GET STATUS OF SELECTED DEVICE
	OR	A			; SET FLAGS
	RET				; AND RETURN
;
;
;
PPA_RESET:
	JP	PPA_INITDEV		; JUST (RE)INIT DEVICE
;
;
;
PPA_DEVICE:
	LD	D,DIODEV_PPA		; D := DEVICE TYPE
	LD	E,(IY+PPA_DEV)		; E := PHYSICAL DEVICE NUMBER
	LD	C,%01111001		; C := REMOVABLE HARD DISK
	LD	H,(IY+PPA_MODE)		; H := MODE
	LD	L,(IY+PPA_IOBASE)	; L := BASE I/O ADDRESS
	XOR	A			; SIGNAL SUCCESS
	RET
;
; PPA_GETMED
;
PPA_MEDIA:
	LD	A,E			; GET FLAGS
	OR	A			; SET FLAGS
	JR	Z,PPA_MEDIA1		; JUST REPORT CURRENT STATUS AND MEDIA
;
	CALL	PPA_RESET		; RESET INCLUDES MEDIA CHECK
;
PPA_MEDIA1:
	LD	A,(IY+PPA_STAT)		; GET STATUS
	OR	A			; SET FLAGS
	LD	D,0			; NO MEDIA CHANGE DETECTED
	LD	E,MID_HD		; ASSUME WE ARE OK
	RET	Z			; RETURN IF GOOD INIT
	LD	E,MID_NONE		; SIGNAL NO MEDIA
	LD	A,ERR_NOMEDIA		; NO MEDIA ERROR
	OR	A			; SET FLAGS
	RET				; AND RETURN
;
;
;
PPA_SEEK:
	BIT	7,D			; CHECK FOR LBA FLAG
	CALL	Z,HB_CHS2LBA		; CLEAR MEANS CHS, CONVERT TO LBA
	RES	7,D			; CLEAR FLAG REGARDLESS (DOES NO HARM IF ALREADY LBA)
	LD	(IY+PPA_LBA+0),L	; SAVE NEW LBA
	LD	(IY+PPA_LBA+1),H	; ...
	LD	(IY+PPA_LBA+2),E	; ...
	LD	(IY+PPA_LBA+3),D	; ...
	XOR	A			; SIGNAL SUCCESS
	RET				; AND RETURN
;
;
;
PPA_CAP:
	LD	A,(IY+PPA_STAT)		; GET STATUS
	PUSH	AF			; SAVE IT
	LD	A,PPA_MEDCAP		; OFFSET TO CAPACITY FIELD
	CALL	LDHLIYA			; HL := IY + A, REG A TRASHED
	CALL	LD32			; GET THE CURRENT CAPACITY INTO DE:HL
	LD	BC,512			; 512 BYTES PER BLOCK
	POP	AF			; RECOVER STATUS
	OR	A			; SET FLAGS
	RET
;
;
;
PPA_GEOM:
	; FOR LBA, WE SIMULATE CHS ACCESS USING 16 HEADS AND 16 SECTORS
	; RETURN HS:CC -> DE:HL, SET HIGH BIT OF D TO INDICATE LBA CAPABLE
	CALL	PPA_CAP			; GET TOTAL BLOCKS IN DE:HL, BLOCK SIZE TO BC
	LD	L,H			; DIVIDE BY 256 FOR # TRACKS
	LD	H,E			; ... HIGH BYTE DISCARDED, RESULT IN HL
	LD	D,16 | $80		; HEADS / CYL = 16, SET LBA CAPABILITY BIT
	LD	E,16			; SECTORS / TRACK = 16
	RET				; DONE, A STILL HAS PPA_CAP STATUS
;
;=============================================================================
; FUNCTION SUPPORT ROUTINES
;=============================================================================
;
; OUTPUT BYTE IN A TO THE DATA PORT
;
PPA_WRITEDATA:
	LD	C,(IY+PPA_IOBASE)	; DATA PORT IS AT IOBASE
	OUT	(C),A			; WRITE THE BYTE
	;CALL	DELAY			; IS THIS NEEDED???
	RET				; DONE
;
;
;
PPA_WRITECTRL:
	; IBM PC INVERTS ALL BUT C2 ON THE BUS, MG014 DOES NOT.
	; BELOW TRANSLATES FROM IBM -> MG014.	IT ALSO INVERTS THE
	; MG014 LED SIMPLY TO MAKE IT EASY TO KEEP LED ON DURING
	; ALL ACTIVITY.
#IF (PPAMODE == PPAMODE_MG014
	XOR	$0B | $80		; HIGH BIT IS MG014 LED
#ENDIF
	LD	C,(IY+PPA_IOBASE)	; GET BASE IO ADDRESS
	INC	C			; BUMP TO CONTROL PORT
	INC	C
	OUT	(C),A			; WRITE TO CONTROL PORT
	;CALL	DELAY			; IS THIS NEEDED?
	RET				; DONE
;
; READ THE PARALLEL PORT INPUT LINES (STATUS) AND MAP SIGNALS FROM
; MG014 TO IBM STANDARD.  NOTE POLARITY CHANGE REQUIRED FOR BUSY.
;
; 	MG014		IBM PC
;	--------	--------
;	0: /ACK		6: /ACK
;	1: BUSY		7: /BUSY
;	2: POUT		5: POUT
;	3: SEL		4: SEL
;	4: /ERR		3: /ERR
;
PPA_READSTATUS:
	LD	C,(IY+PPA_IOBASE)	; IOBASE TO C
	INC	C			; BUMP TO STATUS PORT
	IN	A,(C)			; READ IT
;
#IF (PPAMODE == PPAMODE_MG014
;
	; SHUFFLE BITS ON MG014
	LD	C,0			; INIT RESULT
	BIT	0,A			; 0: /ACK
	JR	Z,PPA_READSTATUS1
	SET	6,C			; 6: /ACK
PPA_READSTATUS1:
	BIT	1,A			; 1: BUSY
	JR	NZ,PPA_READSTATUS2	; POLARITY CHANGE!
	SET	7,C			; 7: /BUSY
PPA_READSTATUS2:
	BIT	2,A			; 2: POUT
	JR	Z,PPA_READSTATUS3
	SET	5,C			; 5: POUT
PPA_READSTATUS3:
	BIT	3,A			; 3: SEL
	JR	Z,PPA_READSTATUS4
	SET	4,C			; 4: SEL
PPA_READSTATUS4:
	BIT	4,A			; 4: /ERR
	JR	Z,PPA_READSTATUS5
	SET	3,C			; 3: /ERR
PPA_READSTATUS5:
	LD	A,C			; RESULT TO A
;
#ENDIF
;
	RET
;
;
;
PPA_DPULSE:
	CALL	PPA_WRITEDATA
	PPA_WCTL($0C)
	PPA_WCTL($0E)
	PPA_WCTL($0C)
	PPA_WCTL($04)
	PPA_WCTL($0C)
	RET
;
;
;
PPA_CPULSE:
	CALL	PPA_WRITEDATA
	PPA_WCTL($04)
	PPA_WCTL($06)
	PPA_WCTL($04)
	PPA_WCTL($0C)
	RET
;
;
;
PPA_CONNECT:
	PPA_CPUL($00)
	PPA_CPUL($3C)
	PPA_CPUL($20)
	PPA_CPUL($8F)
	RET
;
;
;
PPA_DISCONNECT:
	PPA_DPUL($00)
	PPA_DPUL($3C)
	PPA_DPUL($20)
	PPA_DPUL($0F)
;
	; TURNS OFF MG014 LED
	PPA_WCTL($8C)
;
	RET
;
; INITIATE A SCSI BUS RESET.
;
PPA_RESETPULSE:
	PPA_WDATA($40)
	PPA_WCTL($08)
	CALL	DELAY		; 32 US, IDEALLY 30 US
	PPA_WCTL($0C)
	RET
;
; SCSI SELECT PROCESS
;
PPA_SELECT:
#IF (PPATRACE >= 3)
	PRTS("\r\nSELECT: $")
#ENDIF
;
#IF (PPATRACE >= 3)
	CALL	PPA_READSTATUS
	CALL	PC_SPACE
	CALL	PRTHEXBYTE
#ENDIF
;
	LD	A,1 << PPA_TGT
	CALL	PPA_WRITEDATA
	PPA_WCTL($0E)
	PPA_WCTL($0C)
	LD	A,1 << PPA_SELF
	CALL	PPA_WRITEDATA
	PPA_WCTL($08)
;
	LD	B,0			; TIMEOUT COUNTER
PPA_SELECT1:
	CALL	PPA_READSTATUS
#IF (PPATRACE >= 3)
	CALL	PC_SPACE
	CALL	PRTHEXBYTE
#ENDIF
	AND	$40
	CP	$40
	RET	Z
	DJNZ	PPA_SELECT1
	JP	PPA_CMD_TIMEOUT
;
; SEND SCSI CMD BYTE STRING.  AT ENTRY, HL POINTS TO START OF
; COMMAND BYTES.  THE LENGTH OF THE COMMAND STRING MUST PRECEED
; THE COMMAND BYTES (HL - 1).
;
; NOTE THAT DATA IS SENT AS BYTE PAIRS!  EACH LOOP SENDS 2 BYTES.
; DATA OUTPOUT IS BURSTED (NO CHECK FOR BUSY).  SEEMS TO WORK FINE.
;
PPA_SENDCMD:
;
#IF (PPATRACE >= 3)
	PRTS("\r\nSENDCMD:$")
#ENDIF
;
	DEC	HL		; BACKUP TO LENGTH BYTE
	LD	B,(HL)		; PUT IN B FOR LOOP COUNTER
;
#IF (PPATRACE >= 3)
	LD	A,B
	CALL	PC_SPACE
	CALL	PRTHEXBYTE
	PRTS(" BYTES$")
#ENDIF
;
	INC	HL		; BACK TO FIRST CMD BYTE
;
PPA_SENDCMD1:
	;PPA_WCTL($0C)
	LD	A,(HL)		; LOAD CMD BYTE
;
#IF (PPATRACE >= 3)
	CALL	PC_SPACE
	CALL	PRTHEXBYTE
#ENDIF
;
	CALL	PPA_WRITEDATA	; PUT IT ON THE BUS
	INC	HL		; BUMP TO NEXT BYTE
	PPA_WCTL($0E)
	PPA_WCTL($0C)
	DJNZ	PPA_SENDCMD1	; LOOP TILL DONE
;
	RET
;
;
; WAIT FOR SCSI BUS TO BECOME READY WITH A TIMEOUT.
;
PPA_WAITLOOP:
	CALL	PPA_READSTATUS
	BIT	7,A
	RET	NZ			; DONE, STATUS IN A
	DEC	HL
	LD	A,H
	OR	L
	RET	Z			; TIMEOUT
	JR	PPA_WAITLOOP
;
PPA_WAIT:
	LD	HL,500			; GOOD VALUE???
	PPA_WCTL($0C)
	CALL	PPA_WAITLOOP
	JP	Z,PPA_CMD_TIMEOUT	; HANDLE TIMEOUT
	;PUSH	AF
	;IMM_WCTL($04)
	;POP	AF
	AND	$F0
	RET				; RETURN W/ RESULT IN A
;
; MAX OBSERVED WAITLOOP ITERATIONS IS $0116B3 @ 7.372 MHZ ON MG014
; MAX OBSERVED WAITLOOP ITERATIONS IS $028EFE @ 8.000 MHZ ON MBC SPP
;
PPA_LONGWAIT:
	LD	A,(CB_CPUMHZ)		; LOAD CPU SPEED IN MHZ
	SRL	A			; DIVIDE BY 2, GOOD ENOUGH
	LD	B,A			; USE FOR OUTER LOOP COUNT
	PPA_WCTL($0C)
PPA_LONGWAIT1:
	LD	HL,0
	CALL	PPA_WAITLOOP
	JR	NZ,PPA_LONGWAIT2	; HANDLE SUCCESS
	DJNZ	PPA_LONGWAIT1		; LOOP TILL COUNTER EXHAUSTED
	JP	PPA_CMD_TIMEOUT		; HANDLE TIMEOUT
;
PPA_LONGWAIT2:
	;PUSH	AF
	;PPA_WCTL($04)
;
#IF 0
	PUSH	AF
	CALL	PC_GT
	LD	A,B
	CALL	PRTHEXBYTE
	CALL	PC_COLON
	CALL	PRTHEXWORDHL
	POP	AF
#ENDIF
;
	;POP	AF
	AND	$F0
	RET				; RETURN W/ RESULT IN A
;
; GET A BYTE OF DATA FROM THE SCSI DEVICE.  THIS IS A NIBBLE READ.
; BYTE RETURNED IN A.
;
PPA_GETBYTE:
	CALL	PPA_WAIT
	PPA_WCTL($04)
	CALL	PPA_READSTATUS
	AND	$F0
	PUSH 	AF
	PPA_WCTL($06)
	CALL	PPA_READSTATUS
	AND	$F0
	RRCA
	RRCA
	RRCA
	RRCA
	POP	HL
	OR	H
	PUSH	AF
	PPA_WCTL($0C)
	POP	AF
	RET
;
; GET A CHUNK OF DATA FROM SCSI BUS.  THIS IS SPECIFICALLY FOR
; READ PHASE.  IF TRANSFER MODE IS NON-ZERO, THEN A BLOCK (512 BYTES)
; OF DATA WILL BE READ.  OTHERWISE, DATA IS WRITTEN AS
; LONG AS SCSI DEVICE WANTS TO CONTINUE RECEIVING (NO OVERRUN
; CHECK IN THIS CASE).
;
; THIS IS A NIBBLE READ.
;
; DE=BUFFER
; A=TRANSFER MODE (0=VARIABLE, 1=BLOCK)
;
PPA_GETDATA:
	; BRANCH TO CORRECT ROUTINE
	OR	A
	JR	NZ,PPA_GETBLOCK		; DO BLOCK READ
;
#IF (PPATRACE >= 3)
	PRTS("\r\nGETDATA:$")
#ENDIF
;
PPA_GETDATA1:
	PUSH	HL			; SAVE BYTE COUNTER
	CALL	PPA_WAIT		; WAIT FOR BUS READY
	POP	HL			; RESTORE BYTE COUNTER
	CP	$D0			; CHECK FOR READ PHASE
	JR	NZ,PPA_GETDATA2		; IF NOT, ASSUME WE ARE DONE
	PPA_WCTL($04)
	CALL	PPA_READSTATUS		; GET FIRST NIBBLE
	AND	$F0			; ISOLATE BITS
	PUSH 	AF			; SAVE WORKING VALUE
	PPA_WCTL($06)
	CALL	PPA_READSTATUS		; GET SECOND NIBBLE
	AND	$F0			; ISOLATE BITS
	RRCA				; AND SHIFT TO LOW NIBBLE
	RRCA
	RRCA
	RRCA
	POP	BC			; RECOVER LOW NIBBLE
	OR	B			; COMBINE
	LD	(DE),A			; AND SAVE THE FULL BYTE VALUE
	INC	DE			; NEXT BUFFER POS
	INC	HL			; INCREMENT BYTES COUNTER
	JR	PPA_GETDATA1		; LOOP TILL DONE
;
PPA_GETDATA2:
;
#IF (PPATRACE >= 3)
	CALL	PC_SPACE
	CALL	PRTHEXWORDHL
	PRTS(" BYTES$")
#ENDIF
;
	PPA_WCTL($0C)
	RET
;
PPA_GETBLOCK:
;
#IF (PPATRACE >= 3)
	PRTS("\r\nGETBLK:$")
#ENDIF
	LD	B,0			; LOOP COUNTER
	EXX				; SWITCH TO ALT
	EX	AF,AF'			; SWITCH TO ALT AF
	; SAVE ALT REGS
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	; C: PORT C	
	LD	A,(IY+PPA_IOBASE)	; BASE PORT
	INC	A			; STATUS PORT
	LD	(PPA_GETBLOCK_A),A	; FILL IN
	LD	(PPA_GETBLOCK_B),A	; ... DYNAMIC BITS OF CODE
	INC	A			; CONTROL PORT
	LD	C,A			; ... TO C
#IF (PPAMODE == PPAMODE_MG014)
	; DE: CLOCK VALUES
	LD	D,$04 ^ ($0B | $80)
	LD	E,$06 ^ ($0B | $80)
	; HL: STATMAP
	LD	H,MG014_STATMAPLO >> 8
#ENDIF
#IF (PPAMODE == PPAMODE_SPP)
	; DE: CLOCK VALUES
	LD	D,$04
	LD	E,$06
#ENDIF
	EXX				; SWITCH TO PRI
	CALL	PPA_GETBLOCK1		; LOOP TWICE
	CALL	PPA_GETBLOCK1		; ... FOR 512 BYTES
	; RESTORE ALT REGS
	EXX				; SWITCH TO ALT REGS
	EX	AF,AF'			; SWITCH TO ALT AF
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	EXX				; SWITCH TO PRI REGS
	EX	AF,AF'			; SWITCH TO PRI AF
	RET
;
;
PPA_GETBLOCK1:
	EXX				; ALT REGS
	OUT	(C),D			; SEND FIRST CLOCK
PPA_GETBLOCK_A	.EQU	$+1
	IN	A,($FF)			; GET HIGH NIBBLE
#IF (PPAMODE == PPAMODE_MG014)
	AND	$0F			; RELEVANT BITS ONLY
	ADD	A,MG014_STATMAPHI & $FF	; HIGH BYTE OF MAP PTR
	LD	L,A			; PUT IN L
	LD	A,(HL)			; LOOKUP HIGH NIBBLE VALUE
	EX	AF,AF'			; SAVE NIBBLE
#ENDIF
#IF (PPAMODE == PPAMODE_SPP)
	AND	$F0			; RELEVANT BITS ONLY
	LD	L,A			; SAVE NIBBLE IN L
#ENDIF
	OUT	(C),E			; SEND SECOND CLOCK
PPA_GETBLOCK_B	.EQU	$+1
	IN	A,($FF)			; GET LOW NIBBLE
#IF (PPAMODE == PPAMODE_MG014)
	AND	$0F			; RELEVANT BITS ONLY
	ADD	A,MG014_STATMAPLO & $FF	; LOW BYTE OF MAP PTR
	LD	L,A			; PUT IN L
	EX	AF,AF'			; RECOVER HIGH NIBBLE VALUE
	OR	(HL)			; COMBINE WITH LOW NIB VALUE
#ENDIF
#IF (PPAMODE == PPAMODE_SPP)
	AND	$F0			; RELEVANT BITS ONLY
	RLCA				; MOVE TO LOW NIBBLE
	RLCA				; MOVE TO LOW NIBBLE
	RLCA				; MOVE TO LOW NIBBLE
	RLCA				; MOVE TO LOW NIBBLE
	OR	L			; COMBINE WITH HIGH NIB VALUE
#ENDIF
	EXX				; SWITCH TO PRI
	LD	(DE),A			; SAVE BYTE
	INC	DE			; BUMP BUF PTR
	DJNZ	PPA_GETBLOCK1		; LOOP
	RET				; DONE
;
; PUT A CHUNK OF DATA TO THE SCSI BUS.  THIS IS SPECIFICALLY FOR
; WRITE PHASE.  IF TRANSFER MODE IS NON-ZERO, THEN A BLOCK (512 BYTES)
; OF DATA WILL BE WRITTEN.  OTHERWISE, DATA IS WRITTEN AS
; LONG AS SCSI DEVICE WANTS TO CONTINUE RECEIVING (NO OVERRUN
; CHECK IN THIS CASE).
;
; DE=BUFFER
; A=TRANSFER MODE (0=VARIABLE, 1=BLOCK)
;
PPA_PUTDATA:
	; BRANCH TO CORRECT ROUTINE
	OR	A
	JR	NZ,PPA_PUTBLOCK		; DO BLOCK WRITE
;
#IF (PPATRACE >= 3)
	PRTS("\r\nPUTDATA:$")
#ENDIF
;
PPA_PUTDATA1:
	PUSH	HL			; SAVE BYTE COUNTER
	CALL	PPA_WAIT		; WAIT FOR BUS READY
	POP	HL			; RESTORE BYTE COUNTER
	CP	$C0			; CHECK FOR WRITE PHASE
	JR	NZ,PPA_PUTDATA2		; IF NOT, ASSUME WE ARE DONE
	LD	A,(DE)			; GET NEXT BYTE TO WRITE (FIRST OF PAIR)
	CALL	PPA_WRITEDATA		; PUT ON BUS
	INC	DE			; BUMP TO NEXT BUF POS
	INC	HL			; INCREMENT COUNTER
	PPA_WCTL($0E)
	PPA_WCTL($0C)
	LD	A,(DE)			; GET NEXT BYTE TO WRITE (SECOND OF PAIR)
	JR	PPA_PUTDATA1		; LOOP TILL DONE
;
PPA_PUTDATA2:
;
#IF (PPATRACE >= 3)
	CALL	PC_SPACE
	CALL	PRTHEXWORDHL
	PRTS(" BYTES$")
#ENDIF
;
	RET
;
PPA_PUTBLOCK:
;
#IF (PPATRACE >= 3)
	PRTS("\r\nPUTBLK:$")
#ENDIF
;
	LD	B,0			; LOOP COUNTER
	LD	A,(IY+PPA_IOBASE)	; GET BASE IO ADR
	LD	(PPA_PUTBLOCK_A),A	; FILL IN
	INC	A			; STATUS PORT
	INC	A			; CONTROL PORT
	LD	C,A			; ... TO C
	; HL: CLOCK VALUES
#IF (PPAMODE == PPAMODE_MG014)
	LD	H,$0E ^ ($0B | $80)
	LD	L,$0C ^ ($0B | $80)
#ENDIF
#IF (PPAMODE == PPAMODE_SPP)
	LD	H,$0E
	LD	L,$0C
#ENDIF
	CALL	PPA_PUTBLOCK1		; DO BELOW TWICE
	CALL	PPA_PUTBLOCK1		; ... FOR 512 BYTES
	RET
;
PPA_PUTBLOCK1:
	LD	A,(DE)			; GET NEXT BYTE
PPA_PUTBLOCK_A	.EQU	$+1
	OUT	($FF),A			; PUT ON BUS
	INC	DE			; INCREMENT BUF POS
	OUT	(C),H			; FIRST CLOCK
	OUT	(C),L			; SECOND CLOCK
	DJNZ	PPA_PUTBLOCK1		; LOOP
	RET				; DONE
;
; READ SCSI COMMAND STATUS
;
PPA_GETSTATUS:
;
#IF (PPATRACE >= 3)
	PRTS("\r\nSTATUS:$")
#ENDIF
;
	CALL	PPA_GETBYTE		; GET ONE BYTE
	LD	(PPA_CMDSTAT),A		; SAVE AS FIRST STATUS BYTE
;
#IF (PPATRACE >= 3)
	CALL	PC_SPACE
	CALL	PRTHEXBYTE
#ENDIF
;
	CALL	PPA_WAIT		; CHECK FOR OPTIONAL SECOND BYTE
	CP	$F0			; STILL IN STATUS PHASE?
	RET	NZ			; IF NOT, DONE
	CALL	PPA_GETBYTE		; ELSE, GET THE SECOND BYTE
	LD	(PPA_CMDSTAT+1),A	; AND SAVE IT
;
#IF (PPATRACE >= 3)
	CALL	PC_SPACE
	CALL	PRTHEXBYTE
#ENDIF
;
	RET
;
; THIS IS THE MAIN SCSI ENGINE.  BASICALLY, IT SELECTS THE DEVICE
; ON THE BUS, SENDS THE COMMAND, THEN PROCESSES THE RESULT.
;
; HL: COMMAND BUFFER
; DE: TRANSFER BUFFER
; A: TRANSFER MODE (0=VARIABLE, 1=BLOCK)
;
PPA_RUNCMD:
	; THERE ARE MANY PLACES NESTED WITHIN THE ROUTINES THAT
	; ARE CALLED HERE.  HERE WE SAVE THE STACK SO THAT WE CAN
	; EASILY AND QUICKLY ABORT OUT OF ANY NESTED ROUTINE.
	; SEE PPA_CMD_ERR BELOW.
	LD	(PPA_CMDSTK),SP		; FOR ERROR ABORTS
	LD	(PPA_DSKBUF),DE		; SAVE BUF PTR
	LD	(PPA_XFRMODE),A		; SAVE XFER LEN
	PUSH	HL
	CALL	PPA_CONNECT		; PARALLEL PORT BUS CONNECT
	CALL	PPA_SELECT		; SELECT TARGET DEVICE
	CALL	PPA_WAIT		; WAIT TILL READY
	POP	HL
	CALL	PPA_SENDCMD		; SEND THE COMMAND
;
PPA_RUNCMD_PHASE:
	; WAIT FOR THE BUS TO BE READY.  WE USE AN EXTRA LONG WAIT
	; TIMEOUT HERE BECAUSE THIS IS WHERE WE WILL WAIT FOR LONG
	; OPERATIONS TO COMPLETE.  IT CAN TAKE SOME TIME IF THE
	; DEVICE HAS GONE TO SLEEP BECAUSE IT WILL NEED TO WAKE UP
	; AND SPIN UP BEFORE PROCESSING AN I/O COMMAND.
	CALL	PPA_LONGWAIT		; WAIT TILL READY
;
#IF (PPATRACE >= 3)
	PRTS("\r\nPHASE: $")
	CALL	PRTHEXBYTE
#ENDIF
;
	CP	$C0			; DEVICE WANTS TO RCV DATA
	JR	Z,PPA_RUNCMD_WRITE
	CP	$D0			; DEVICE WANTS TO SEND DATA
	JR	Z,PPA_RUNCMD_READ
	CP	$F0			; DEVICE WANTS TO BE DONE
	JR	Z,PPA_RUNCMD_END
	JR	PPA_CMD_IOERR
;
PPA_RUNCMD_WRITE:
	LD	DE,(PPA_DSKBUF)		; XFER BUFFER
	LD	A,(PPA_XFRMODE)		; XFER MODE
	CALL	PPA_PUTDATA		; SEND DATA NOW
	JR	PPA_RUNCMD_PHASE	; BACK TO DISPATCH
;
PPA_RUNCMD_READ:
	LD	DE,(PPA_DSKBUF)		; XFER BUFFER
	LD	A,(PPA_XFRMODE)		; XFER MODE
	CALL	PPA_GETDATA		; GET THE DATA NOW
	JR	PPA_RUNCMD_PHASE	; BACK TO DISPATCH
;
PPA_RUNCMD_END:
	CALL	PPA_GETSTATUS		; READ STATUS BYTES
	CALL	PPA_DISCONNECT		; PARALLEL PORT BUS DISCONNECT
	XOR	A			; SIGNAL SUCCESS
	RET
;
PPA_CMD_IOERR:
	LD	A,PPA_STIOERR		; ERROR VALUE TO A
	JR	PPA_CMD_ERR		; CONTINUE
;
PPA_CMD_TIMEOUT:
	LD	A,PPA_STTO		; ERROR VALUE TO A
	JR	PPA_CMD_ERR		; CONTINUE
;
PPA_CMD_ERR:
	LD	SP,(PPA_CMDSTK)		; UNWIND STACK
	PUSH	AF			; SAVE STATUS
	;CALL	PPA_RESETPULSE		; CLEAN UP THE MESS???
	LD	DE,62			; DELAY AFTER RESET PULSE
	CALL	VDELAY
	CALL	PPA_DISCONNECT		; PARALLEL PORT BUS DISCONNECT
	LD	DE,62			; DELAY AFTER DISCONNECT
	CALL	VDELAY
	POP	AF			; RECOVER STATUS
	JP	PPA_ERR			; NOW DO STANDARD ERR PROCESSING
;
; ERRORS SHOULD GENERALLY NOT CAUSE SCSI PROCESSING TO FAIL.  IF A
; DEVICE ERROR (I.E., READ ERROR) OCCURS, THEN THE SCSI PROTOCOL WILL
; PROVIDE ERROR INFORMATION.  THE STATUS RESULT OF THE SCSI COMMAND
; WILL INDICATE IF AN ERROR OCCURRED.  ADDITIONALLY, IF THE ERROR IS
; A CHECK CONDITION ERROR, THEN IT IS MANDATORY TO ISSUE A SENSE
; REQUEST SCSI COMMAND TO CLEAR THE ERROR AND RETRIEVE DETAILED ERROR
; INFO.
;
PPA_CHKCMD:
	; SCSI COMMAND COMPLETED, CHECK SCSI CMD STATUS
	LD	A,(PPA_CMDSTAT)		; GET STATUS BYTE
	OR	A			; SET FLAGS
	RET	Z			; IF ZERO, ALL GOOD, DONE
;
	; DO WE HAVE A CHECK CONDITION?
	CP	2			; CHECK CONDITION RESULT?
	JR	Z,PPA_CHKCMD1		; IF SO, REQUEST SENSE
	JP	PPA_IOERR		; ELSE, GENERAL I/O ERROR
;
PPA_CHKCMD1:
	; USE REQUEST SENSE CMD TO GET ERROR DETAILS
	LD	DE,HB_WRKBUF		; PUT DATA IN WORK BUF
	LD	A,0			; VARIABLE LENGTH READ
	LD	HL,PPA_CMD_SENSE	; REQUEST SENSE CMD
	CALL	PPA_RUNCMD		; DO IT
	JP	NZ,PPA_IOERR		; BAIL IF ERROR IN CMD
;
	; REQ SENSE CMD COMPLETED
#IF (PPATRACE >= 3)
	PRTS("\r\nSENSE:$")
	LD	A,$19
	LD	DE,HB_WRKBUF
	CALL	Z,PRTHEXBUF
#ENDIF
;
	; CHECK SCSI CMD STATUS
	LD	A,(PPA_CMDSTAT)		; GET STATUS BYTE
	OR	A			; SET FLAGS
	JP	NZ,PPA_IOERR		; IF FAILED, GENERAL I/O ERROR
;
	; RETURN RESULT BASED ON REQ SENSE DATA
	; TODO: WE NEED TO CHECK THE SENSE KEY FIRST!!!
	LD	A,(HB_WRKBUF+12)	; GET ADDITIONAL SENSE CODE
	CP	$3A			; NO MEDIA?
	JP	Z,PPA_NOMEDIA		; IF SO, RETURN NO MEDIA ERR
	JP	PPA_IOERR		; ELSE GENERAL I/O ERR
;
; CHECK CURRENT DEVICE FOR ERROR STATUS AND ATTEMPT TO RECOVER
; VIA RESET IF DEVICE IS IN ERROR.
;
PPA_CHKERR:
	LD	A,(IY+PPA_STAT)		; GET STATUS
	OR	A			; SET FLAGS
	CALL	NZ,PPA_RESET		; IF ERROR STATUS, RESET BUS
	RET
;
; (RE)INITIALIZE DEVICE
;
PPA_INITDEV:
;
#IF (PPAMODE == PPAMODE_MG014)
	; INITIALIZE 8255
	LD	A,(IY+PPA_IOBASE)	; BASE PORT
	ADD	A,PPA_IOSETUP		; BUMP TO SETUP PORT
	LD	C,A			; MOVE TO C FOR I/O
	LD	A,$82			; CONFIG A OUT, B IN, C OUT
	OUT	(C),A			; DO IT
	CALL	DELAY			; SHORT DELAY FOR BUS SETTLE
#ENDIF
;
	; BUS RESET
	CALL	PPA_CONNECT
	CALL	PPA_RESETPULSE
	LD	DE,62			; 1000 US
	CALL	VDELAY
	CALL	PPA_DISCONNECT
	LD	DE,62			; 1000 US
	CALL	VDELAY
;
	; INITIALLY, THE DEVICE MAY REQUIRE MULTIPLE REQUEST SENSE
	; COMMANDS BEFORE IT WILL ACCEPT I/O COMMANDS.  THIS IS DUE
	; TO THINGS LIKE BUS RESET NOTIFICATION, MEDIA CHANGE, ETC.
	; HERE, WE RUN A FEW REQUEST SENSE COMMANDS.  AS SOON AS ONE
	; INDICATES NO ERRORS, WE CAN CONTINUE.
	LD	B,4			; TRY UP TO 4 TIMES
PPA_INITDEV1:
	PUSH	BC			; SAVE LOOP COUNTER
;
	; REQUEST SENSE COMMAND
	LD	DE,HB_WRKBUF		; BUFFER FOR SENSE DATA
	LD	A,0			; READ WHATEVER IS SENT
	LD	HL,PPA_CMD_SENSE	; POINT TO CMD BUFFER
	CALL	PPA_RUNCMD		; RUN THE SCSI ENGINE
	JR	NZ,PPA_INITDEV2		; CMD PROC ERROR
;
#IF (PPATRACE >= 3)
	PRTS("\r\nSENSE:$")
	LD	A,$19
	LD	DE,HB_WRKBUF
	CALL	PRTHEXBUF
#ENDIF
;
	; CHECK SENSE KEY
	LD	A,(HB_WRKBUF + 2)	; GET SENSE KEY
	OR	A			; SET FLAGS
;
PPA_INITDEV2:
	POP	BC			; RESTORE LOOP COUNTER
	JR	Z,PPA_INITDEV3		; IF NO ERROR, MOVE ON
	DJNZ	PPA_INITDEV1		; TRY UNTIL COUNTER EXHAUSTED
	JP	PPA_IOERR		; BAIL OUT WITH ERROR
;
PPA_INITDEV3:
	; READ & RECORD DEVICE CAPACITY
	LD	DE,HB_WRKBUF		; BUFFER TO CAPACITY RESPONSE
	LD	A,0			; READ WHATEVER IS SENT
	LD	HL,PPA_CMD_RDCAP	; POINT TO READ CAPACITY CMD
	CALL	PPA_RUNCMD		; RUN THE SCSI ENGINE
	CALL	Z,PPA_CHKCMD		; CHECK AND RECORD ANY ERRORS
	RET	NZ			; BAIL OUT ON ERROR
;
#IF (PPATRACE >= 3)
	PRTS("\r\nRDCAP:$")
	LD	A,8
	LD	DE,HB_WRKBUF
	CALL	PRTHEXBUF
#ENDIF
;
	; CAPACITY IS RETURNED IN A 4 BYTE, BIG ENDIAN FIELD AND
	; INDICATES THE LAST LBA VALUE.  WE NEED TO CONVERT THIS TO
	; LITTLE ENDIAN AND INCREMENT THE VALUE TO MAKE IT A CAPACITY
	; COUNT INSTEAD OF A LAST LBA VALUE.
	LD	A,PPA_MEDCAP		; OFFSET IN CFG FOR CAPACITY
	CALL	LDHLIYA			; POINTER TO HL
	PUSH	HL			; SAVE IT
	LD	HL,HB_WRKBUF		; POINT TO VALUE IN CMD RESULT
	CALL	LD32			; LOAD IT TO DE:HL
	LD	A,L			; FLIP BYTES
	LD	L,D			; ... BIG ENDIAN
	LD	D,A			; ... TO LITTLE ENDIAN
	LD	A,H
	LD	H,E
	LD	E,A
	CALL	INC32			; INCREMENT TO FINAL VALUE
	POP	BC			; RECOVER SAVE LOCATION
	CALL	ST32			; STORE VALUE
;
	XOR	A			; SIGNAL SUCCESS
	LD	(IY+PPA_STAT),A		; RECORD IT
	RET
;
;=============================================================================
; ERROR HANDLING AND DIAGNOSTICS
;=============================================================================
;
; ERROR HANDLERS
;
;
PPA_NOMEDIA:
	LD	A,PPA_STNOMEDIA
	JR	PPA_ERR
;
PPA_CMDERR:
	LD	A,PPA_STCMDERR
	JR	PPA_ERR
;
PPA_IOERR:
	LD	A,PPA_STIOERR
	JR	PPA_ERR
;
PPA_TO:
	LD	A,PPA_STTO
	JR	PPA_ERR
;
PPA_NOTSUP:
	LD	A,PPA_STNOTSUP
	JR	PPA_ERR
;
PPA_ERR:
	LD	(IY+PPA_STAT),A		; SAVE NEW STATUS
;
PPA_ERR2:
#IF (PPATRACE >= 2)
	CALL	PPA_PRTSTAT
#ENDIF
	OR	A			; SET FLAGS
	RET
;
;
;
PPA_PRTERR:
	RET	Z			; DONE IF NO ERRORS
	; FALL THRU TO PPA_PRTSTAT
;
; PRINT FULL DEVICE STATUS LINE
;
PPA_PRTSTAT:
	PUSH	AF
	PUSH	DE
	PUSH	HL
	LD	A,(IY+PPA_STAT)
	CALL	PPA_PRTPREFIX		; PRINT UNIT PREFIX
	CALL	PC_SPACE		; FORMATTING
	CALL	PPA_PRTSTATSTR
	POP	HL
	POP	DE
	POP	AF
	RET
;
; PRINT STATUS STRING
;
PPA_PRTSTATSTR:
	PUSH	AF
	PUSH	DE
	PUSH	HL
	LD	A,(IY+PPA_STAT)
	NEG
	LD	HL,PPA_STR_ST_MAP
	ADD	A,A
	CALL	ADDHLA
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	CALL	WRITESTR
	POP	HL
	POP	DE
	POP	AF
	RET
;
; PRINT DIAGNONSTIC PREFIX
;
PPA_PRTPREFIX:
	PUSH	AF
	CALL	NEWLINE
	PRTS("PPA$")
	LD	A,(IY+PPA_DEV)		; GET CURRENT DEVICE NUM
	CALL	PRTDECB
	CALL	PC_COLON
	POP	AF
	RET
;
;=============================================================================
; STRING DATA
;=============================================================================
;
PPA_STR_ST_MAP:
	.DW		PPA_STR_STOK
	.DW		PPA_STR_STNOMEDIA
	.DW		PPA_STR_STCMDERR
	.DW		PPA_STR_STIOERR
	.DW		PPA_STR_STTO
	.DW		PPA_STR_STNOTSUP
;
PPA_STR_STOK		.TEXT	"OK$"
PPA_STR_STNOMEDIA	.TEXT	"NO MEDIA$"
PPA_STR_STCMDERR	.TEXT	"COMMAND ERROR$"
PPA_STR_STIOERR		.TEXT	"IO ERROR$"
PPA_STR_STTO		.TEXT	"TIMEOUT$"
PPA_STR_STNOTSUP	.TEXT	"NOT SUPPORTED$"
PPA_STR_STUNK		.TEXT	"UNKNOWN ERROR$"
;
PPA_STR_MODE_MAP:
	.DW	PPA_STR_MODE_NONE
	.DW	PPA_STR_MODE_SPP
	.DW	PPA_STR_MODE_MG014
;
PPA_STR_MODE_NONE	.DB	"NONE$"
PPA_STR_MODE_SPP	.DB	"SPP$"
PPA_STR_MODE_MG014	.DB	"MG014$"
;
PPA_STR_NOHW		.TEXT	"NOT PRESENT$"
;
;=============================================================================
; DATA STORAGE
;=============================================================================
;
PPA_DEVNUM	.DB	0		; TEMP DEVICE NUM USED DURING INIT
PPA_CMDSTK	.DW	0		; STACK PTR FOR CMD ABORTING
PPA_DSKBUF	.DW	0		; WORKING DISK BUFFER POINTER
PPA_XFRMODE	.DB	0		; 0=VARIABLE, 1=BLOCK (512 BYTES)
PPA_CMDSTAT	.DB	0, 0		; CMD RESULT STATUS
;
; SCSI COMMAND TEMPLATES (LENGTH PREFIXED)
;
		.DB	6
PPA_CMD_RW	.DB	$00, $00, $00, $00, $01, $00	; READ/WRITE SECTOR
		.DB	6
PPA_CMD_SENSE	.DB	$03, $00, $00, $00, $FF, $00	; REQUEST SENSE DATA
		.DB	10
PPA_CMD_RDCAP	.DB	$25, $00, $00, $00, $00, $00, $00, $00, $00, $00 ; READ CAPACITY
;
; PPA DEVICE CONFIGURATION TABLE
;
PPA_CFG:
;
#IF (PPACNT >= 1)
;
PPA0_CFG:	; DEVICE 0
	.DB	0			; DRIVER DEVICE NUMBER (FILLED DYNAMICALLY)
	.DB	PPAMODE			; DRIVER DEVICE MODE
	.DB	0			; DEVICE STATUS
	.DB	PPA0BASE		; IO BASE ADDRESS
	.DW	0,0			; DEVICE CAPACITY
	.DW	0,0			; CURRENT LBA
;
	DEVECHO	"PPA: MODE="
  #IF (PPAMODE == PPAMODE_SPP)
	DEVECHO	"SPP"
  #ENDIF
  #IF (PPAMODE == PPAMODE_MG014)
	DEVECHO	"MG014"
  #ENDIF
	DEVECHO	", IO="
	DEVECHO	PPA0BASE
	DEVECHO	"\n"
#ENDIF
;
#IF (PPACNT >= 2)
;
PPA1_CFG:	; DEVICE 1
	.DB	0			; DRIVER DEVICE NUMBER (FILLED DYNAMICALLY)
	.DB	PPAMODE			; DRIVER DEVICE MODE
	.DB	0			; DEVICE STATUS
	.DB	PPA1BASE		; IO BASE ADDRESS
	.DW	0,0			; DEVICE CAPACITY
	.DW	0,0			; CURRENT LBA
;
	DEVECHO	"PPA: MODE="
  #IF (PPAMODE == PPAMODE_SPP)
	DEVECHO	"SPP"
  #ENDIF
  #IF (PPAMODE == PPAMODE_MG014)
	DEVECHO	"MG014"
  #ENDIF
	DEVECHO	", IO="
	DEVECHO	PPA1BASE
	DEVECHO	"\n"
#ENDIF
;
#IF ($ - PPA_CFG) != (PPACNT * PPA_CFGSIZ)
	.ECHO	"*** INVALID PPA CONFIG TABLE ***\n"
#ENDIF
;
	.DB	$FF			; END MARKER
