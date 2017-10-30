        include "config.inc"

        global  usart_init, usart_send, usart_recv, usart_isr, usart_send_str
        global  usart_send_nowait, usart_recv_nowait
        global  usart_send_h4, usart_send_h8, usart_send_h16, usart_send_h32
        global  usart_send_s16, usart_send_u16
        global  usart_send_nl

BAUD    EQU     9600
BUFSIZE EQU     16
BUFMASK EQU     15

.usartd0 udata_acs
tmp     res     1               ; temporary value
xmtr    res     1               ; send queue read index
xmtw    res     1               ; send queue write index
rcvr    res     1               ; recv queue read index
rcvw    res     1               ; recv queue write index
fsrbk   res     2               ; fsr backup

.usartd1 udata
xmtbuf  res     BUFSIZE         ; write buffer
rcvbuf  res     BUFSIZE         ; read buffer
digits  res     5               ; digits for BCD conversion

.usartc code

usart_isr:
        btfss   PIR1, RCIF, A
        bra     usart_isr_rx_end
        btfss   RCSTA, OERR, A  ; overrun
        bra     usart_isr_oerr_end
        bcf     RCSTA, CREN, A
        bsf     RCSTA, CREN, A  ; recover from overrun
        bra     usart_isr_rx_end
usart_isr_oerr_end:
        btfss   RCSTA, FERR, A  ; frame error
        bra     usart_isr_ferr_end
        movf    RCREG, W, A     ; recover from frame error
        bra     usart_isr_rx_end
usart_isr_ferr_end:
        movf    rcvr, W, A
        addlw   BUFSIZE
        subwf   rcvw, W, A
        bnz     usart_isr_full_end ; queue full, character lost
        movf    RCREG, W, A
        bra     usart_isr_rx_end
usart_isr_full_end:
        movff   FSR0L, fsrbk+0  ; backup FSR0
        movff   FSR0H, fsrbk+1
        lfsr    FSR0, rcvbuf
        movf    rcvw, W, A
        andlw   BUFMASK
        movff   RCREG, PLUSW0   ; save the data
        incf    rcvw, F, A      ; publish
        movff   fsrbk+0, FSR0L  ; restore FSR0
        movff   fsrbk+1, FSR0H
usart_isr_rx_end:

        btfss   PIR1, TXIF, A
        bra     usart_isr_tx_end
        movf    xmtr, W, A
        subwf   xmtw, W, A
        bz      usart_isr_tx_err ; queue empty
        movff   FSR0L, fsrbk+0   ; backup FSR0
        movff   FSR0H, fsrbk+1
        lfsr    FSR0, xmtbuf
        movf    xmtr, W, A
        andlw   BUFMASK
        movf    PLUSW0, W, A
        movwf   TXREG, A        ; get the data
        incf    xmtr, F, A      ; consume
        movff   fsrbk+0, FSR0L  ; restore FSR0
        movff   fsrbk+1, FSR0H
        bra     usart_isr_tx_end
usart_isr_tx_err:
        bcf     PIE1, TXIE, A   ; disable TX interrupts
usart_isr_tx_end:
        return

        ;; initialize the usart module
usart_init:
        bsf     RCSTA, SPEN, A  ; enable the usart module
        bsf     TRISC, 7, A     ; RX pin
        bsf     TRISC, 6, A     ; TX pin
        bcf     TXSTA, SYNC, A  ; asynchronous mode
        bsf     TXSTA, BRGH, A  ; high speed mode
        bsf     BAUDCON, BRG16, A ; high precision BRG (16bit)
        movlw   LOW(FOSC/4/BAUD-1)
        movwf   SPBRG, A
        movlw   HIGH(FOSC/4/BAUD-1)
        movwf   SPBRGH, A
        bsf     PIE1, RCIE, A   ; enable RX interrupts
        bcf     PIE1, TXIE, A   ; disable TX interrupts
        bsf     TXSTA, TXEN, A  ; enable tx
        bsf     RCSTA, CREN, A  ; enable rx
        clrf    xmtr, A         ; clear the send queue read index
        clrf    xmtw, A         ; clear the send queue write index
        clrf    rcvr, A         ; clear the recv queue read index
        clrf    rcvw, A         ; clear the recv queue write index
        return

        ;; recv a byte in W
        ;; return if the queue is empty with C = 1
usart_recv_nowait:
        movf    rcvr, W, A
        subwf   rcvw, W, A
        bnz     usart_recv_go   ; queue is not empty
        bsf     STATUS, C, A
        return
        ;; recv a byte in W
        ;; wait if the queue is empty
usart_recv:
        movf    rcvr, W, A
        subwf   rcvw, W, A
        bz      usart_recv      ; queue is empty, wait
usart_recv_go:
        lfsr    FSR0, rcvbuf
        movf    rcvr, W, A
        andlw   BUFMASK
        movf    PLUSW0, W, A    ; get the data
        incf    rcvr, F, A      ; consume
        bcf     STATUS, C, A    ; C = 0
        return

        ;; send the byte in W
        ;; return if the queue is full with C=1
usart_send_nowait:
        movwf   tmp, A
        movf    xmtr, W, A
        addlw   BUFSIZE
        subwf   xmtw, W, A
        bnz     usart_send_go
        movf    tmp, W, A
        bsf     STATUS, C, A
        return
        ;; send the byte in W
        ;; wait if the queue is FULL
usart_send:
        movwf   tmp, A          ; store W in a temporary
usart_send_retry:
        movf    xmtr, W, A
        addlw   BUFSIZE
        subwf   xmtw, W, A
        bz      usart_send_retry ; queue full, wait
usart_send_go:
        lfsr    FSR0, xmtbuf
        movf    xmtw, W, A
        andlw   BUFMASK
        movff   tmp, PLUSW0     ; save data
        incf    xmtw, F, A      ; publish
        bsf     PIE1, TXIE, A   ; enable TX interrupts
        bcf     STATUS, C, A    ; C = 0
        return

        ;; send a string in TBLPTR
usart_send_str
        tblrd*+
        movf    TABLAT, W, A    ; read the value and increment pointer
        btfsc   STATUS, Z, A    ; if W == 0
        return
        call    usart_send
        bra     usart_send_str  ; next char

        ;; send a serial newline (\r\n)
usart_send_nl:
        movlw   '\r'
        rcall    usart_send
        movlw   '\n'
        bra     usart_send

        ;; print a 32bit hex value
usart_send_h32:
        movlw   4
        bra     $+4
usart_send_h16:
        movlw   2
        movwf   tmp, A
usart_send_h_loop:
        swapf   INDF0, W, A
        rcall   usart_send_h4
        movf    POSTINC0, W, A
        rcall   usart_send_h4
        decfsz  tmp, F, A
        bra     usart_send_h_loop
        return
        ;; print a 8bit hex value
usart_send_h8:
        swapf   INDF0, W, A     ; most significant nibble
        rcall   usart_send_h4
        movf    INDF0, W, A     ; least significant nibble
        ;; print a 4bit hex value
usart_send_h4:
        andlw   0x0F            ; isolate the lower nibble
        addlw   255 - 9         ; add 256 in two steps but only the
        addlw   9 - 0 + 1       ; last addition affects the final C flag
        btfss   STATUS, C, A
        addlw   'A'-10-'0'      ; letter detected: add 'A'-10-'0'
        addlw   '0'             ; add '0'
        bra     usart_send      ; tail call usart_send

        ;; print a 16bit signed value
usart_send_s16:
        movlw   '+'             ; set the sign of the value
        movf    POSTINC0, F, A  ; *FSR0++
        btfss   POSTDEC0, 7, A  ; *FSR0--
        bra     usart_send_sign
        comf    POSTINC0, F, A  ; *FSR0++
        comf    POSTDEC0, F, A  ; *FSR0--
        incf    POSTINC0, F, A  ; *FSR0++
        btfsc   STATUS, Z, A
        incf    INDF0, F, A     ; *FSR0
        movf    POSTDEC0, F, A  ; *FSR0--
        movlw   '-'
usart_send_sign:
        call    usart_send      ; print the sign of the value

        ;; print a 16bit unsigned value
usart_send_u16:
        call    b16_d5
        lfsr    FSR0, digits
        movlw   5
        movwf   tmp, A
usart_send_u_loop:
        movf    POSTINC0, W, A
        addlw   '0'
        rcall   usart_send
        decfsz  tmp, F, A
        bra     usart_send_u_loop
        return

        ;; b16_d5 - convert a 16bit value to BCD
        ;; @FSR0: address of the 16bit value [LSB, MSB]
        ;;
        ;; Convert a 16bit value pointed by FSR0 into
        ;; 5 digits BCD values saved in digits[5]
        ;;
        ;; Return: no value
b16_d5:
        banksel digits
        movf    POSTINC0, W, A  ; we have to start from MSB
        swapf   INDF0, W, A     ; W  = A2*16 + A3
        iorlw   0xF0            ; W  = A3 - 16
        movwf   digits+1, B     ; B3 = A3 - 16
        addwf   digits+1, F, B  ; B3 = 2*(A3 - 16) = 2A3 - 32
        addlw   226             ; W  = A3 - 16 - 30 = A3 - 46
        movwf   digits+2, B     ; B2 = A3 - 46
        addlw   50              ; W  = A3 - 40 + 50 = A3 + 4
        movwf   digits+4, B     ; B0 = A3 + 4

        movf    POSTDEC0, W, A  ; W  = A3 * 16 + A2
        andlw   0x0F            ; W  = A2
        addwf   digits+2, F, B  ; B2 = A3 + A2 - 46
        addwf   digits+2, F, B  ; B2 = A3 + 2A2 - 46
        addwf   digits+4, F, B  ; B0 = A3 + A2 + 4
        addlw   233             ; W  = A2 - 23
        movwf   digits+3, B     ; B1 = A2 - 23
        addwf   digits+3, F, B  ; B1 = 2*(A2 - 23) = 2A2 - 46
        addwf   digits+3, F, B  ; B1 = 3*(A2 - 23) = 3A2 - 69

        swapf   INDF0, W, A     ; W  = A0 * 16 + A1
        andlw   0x0F            ; W  = A1
        addwf   digits+3, F, B  ; B1 = 3A2 + A1 - 69
        addwf   digits+4, F, B  ; B0 = A3 + A2 + A1 + 4 (C = 0)

        rlcf    digits+3, F, B  ; B1 = 2*(3A2 + A1 - 69) = 6A2 + 2A1 - 138 (C = 1)
        rlcf    digits+4, F, B  ; B0 = 2*(A3+A2+A1+4)+C = 2A3+2A2+2A1+9
        comf    digits+4, F, B  ; B0 = ~(2A3+2A2+2A1+9)= -2A3-2A2-2A1-10
        rlcf    digits+4, F, B  ; B0 = 2*(-2A3-2A2-2A1-10) = -4A3-4A2-4A1-20

        movf    INDF0, W, A     ; W  = A1*16+A0
        andlw   0x0F            ; W  = A0
        addwf   digits+4, F, B  ; B0 = A0-4A3-4A2-4A1-20 (C=0)
        rlcf    digits+1, F, B  ; B3 = 2*(2A3-32) = 4A3 - 64

        movlw   0x07            ; W  = 7
        movwf   digits+0, B     ; B4 = 7

        ;; normalization
        ;; B0 = A0-4(A3+A2+A1)-20 range  -5 .. -200
        ;; B1 = 6A2+2A1-138       range -18 .. -138
        ;; B2 = A3+2A2-46         range  -1 ..  -46
        ;; B3 = 4A3-64            range  -4 ..  -64
        ;; B4 = 7                 7
        movlw   10              ; W  = 10
b16_d5_lb1:                     ; do {
        decf    digits+3, F, B  ;   B1 -= 1
        addwf   digits+4, F, B  ;   B0 += 10
        skpc                    ; } while B0 < 0
        bra     b16_d5_lb1
b16_d5_lb2:                     ; do {
        decf    digits+2, F, B  ;   B2 -= 1
        addwf   digits+3, F, B  ;   B1 += 10
        skpc                    ; } while B1 < 0
        bra     b16_d5_lb2
b16_d5_lb3:                     ; do {
        decf    digits+1, F, B  ;  B3 -= 1
        addwf   digits+2, F, B  ;  B2 += 10
        skpc                    ; } while B2 < 0
        bra     b16_d5_lb3
b16_d5_lb4:                     ; do {
        decf    digits+0, F, B  ;  B4 -= 1
        addwf   digits+1, F, B  ;  B3 += 10
        skpc                    ; } while B3 < 0
        bra     b16_d5_lb4
        retlw   0

        end
