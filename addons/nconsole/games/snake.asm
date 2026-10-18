; Snake for the NConsole.
;
; The field is the background map (rows of 32 tiles, 20 on screen): row 0
; shows the score, rows 1-14 are the arena with walls around it. The snake's cells are kept in a ring
; buffer (body_x/body_y, 256 entries, so an 8-bit index wraps by itself);
; collisions are found by looking at the tile in video RAM.

.title "Snake"

; --- hardware ---
VCTRL   = $3000
BGCOLOR = $3001
PAD1    = $3010
RANDOM  = $3022
MAP     = $2000
; sound: pulse 0 for effects, pulse 1 for tunes, noise for the crash
SND0_PERIOD = $3030
SND0_HI     = $3031
SND0_VOLUME = $3032
SND0_SHAPE  = $3033
SND1_PERIOD = $3034
SND1_HI     = $3035
SND1_VOLUME = $3036
SND1_SHAPE  = $3037
NOISE_RATE  = $303c
NOISE_HI    = $303d
NOISE_VOLUME = $303e
NOISE_SHAPE = $303f

; note periods: CLOCK / (16 * frequency) - 1
REST = 0
C4 = 427
E4 = 338
G4 = 284
A4 = 253
C5 = 213
D5 = 189
E5 = 169
G5 = 142
C6 = 106
E6 = 84

BTN_UP    = $01
BTN_DOWN  = $02
BTN_LEFT  = $04
BTN_RIGHT = $08
BTN_START = $80

; --- game ---
T_EMPTY = 0
T_WALL  = 1
T_BODY  = 2
T_HEAD  = 3
T_FOOD  = 4

DIR_UP    = 0
DIR_DOWN  = 1
DIR_LEFT  = 2
DIR_RIGHT = 3

STATE_TITLE = 0
STATE_PLAY  = 1
STATE_OVER  = 2

START_SPEED = 8     ; frames per step
TOP_SPEED   = 3

; --- variables ---
.section ram
ptr:      .res 2    ; a row of the map
str:      .res 2    ; text to print
cx:       .res 1    ; cell for peek/poke/print
cy:       .res 1
ct:       .res 1
state:    .res 1
pad_prev: .res 1    ; buttons held now
pad_new:  .res 1    ; buttons pressed this frame
dir:      .res 1
next_dir: .res 1
timer:    .res 1
speed:    .res 1
head:     .res 1    ; ring index of the head
tail:     .res 1    ; ring index of the tail
grow:     .res 1    ; steps left to grow
ate:      .res 1
nx:       .res 1
ny:       .res 1
score:    .res 3    ; decimal digits, hundreds first
tune_ptr: .res 2    ; the next note; high byte 0 = no tune
tune_wait: .res 1   ; frames left of the current note
tmp:      .res 1
.org $0300
body_x:   .res 256
body_y:   .res 256

; --- program ---
.section rom
.org $8000

reset:
	ld a, #$01          ; background only
	st a, VCTRL
	ld a, #0
	st a, BGCOLOR
	st a, pad_prev
	call title

main:
	wait
	call tune_tick
	call read_pad
	ld a, state
	cmp #STATE_PLAY
	jz @play
	ld a, pad_new       ; title or game over: start begins a game
	and #BTN_START
	jz main
	call new_game
	jmp main
@play:
	call play_frame
	jmp main

; pad_prev = buttons held, pad_new = those that just went down
read_pad:
	ld a, PAD1
	mov x, a
	xor pad_prev
	st a, pad_new
	mov a, x
	and pad_new
	st a, pad_new
	st x, pad_prev
	ret

title:
	call clear
	ld a, #<txt_snake
	st a, str
	ld a, #>txt_snake
	st a, str+1
	ld a, #5
	st a, cy
	ld a, #7
	st a, cx
	call print
	call print_press_start
	ld a, #STATE_TITLE
	st a, state
	ret

print_press_start:
	ld a, #<txt_start
	st a, str
	ld a, #>txt_start
	st a, str+1
	ld a, #10
	st a, cy
	ld a, #4
	st a, cx
	jmp print

new_game:
	call clear
	call draw_walls
	ld a, #<txt_score
	st a, str
	ld a, #>txt_score
	st a, str+1
	ld a, #0
	st a, cy
	ld a, #1
	st a, cx
	call print
	ld a, #0
	st a, score
	st a, score+1
	st a, score+2
	st a, grow
	st a, ate
	st a, tail
	call draw_score
	; three cells in row 7, heading right
	ld a, #2
	st a, head
	ld a, #7
	st a, body_y
	st a, body_y+1
	st a, body_y+2
	st a, cy
	ld a, #5
	st a, body_x
	st a, cx
	ld a, #T_BODY
	st a, ct
	call poke
	ld a, #6
	st a, body_x+1
	st a, cx
	call poke
	ld a, #7
	st a, body_x+2
	st a, cx
	ld a, #T_HEAD
	st a, ct
	call poke
	ld a, #DIR_RIGHT
	st a, dir
	st a, next_dir
	ld a, #START_SPEED
	st a, speed
	st a, timer
	call place_food
	ld a, #<tune_start
	ld x, #>tune_start
	call start_tune
	ld a, #STATE_PLAY
	st a, state
	ret

play_frame:
	; steer: any direction but straight back
	ld a, pad_prev
	and #BTN_UP
	jz @no_up
	ld a, dir
	cmp #DIR_DOWN
	jz @no_up
	ld a, #DIR_UP
	st a, next_dir
@no_up:
	ld a, pad_prev
	and #BTN_DOWN
	jz @no_down
	ld a, dir
	cmp #DIR_UP
	jz @no_down
	ld a, #DIR_DOWN
	st a, next_dir
@no_down:
	ld a, pad_prev
	and #BTN_LEFT
	jz @no_left
	ld a, dir
	cmp #DIR_RIGHT
	jz @no_left
	ld a, #DIR_LEFT
	st a, next_dir
@no_left:
	ld a, pad_prev
	and #BTN_RIGHT
	jz @no_right
	ld a, dir
	cmp #DIR_LEFT
	jz @no_right
	ld a, #DIR_RIGHT
	st a, next_dir
@no_right:
	dec timer
	jz @step
	ret
@step:
	ld a, speed
	st a, timer
	ld a, next_dir
	st a, dir
	; the cell in front of the head
	ld x, head
	ld a, body_x,x
	st a, nx
	ld a, body_y,x
	st a, ny
	ld a, dir
	cmp #DIR_UP
	jnz @d1
	dec ny
	jr @look
@d1:
	cmp #DIR_DOWN
	jnz @d2
	inc ny
	jr @look
@d2:
	cmp #DIR_LEFT
	jnz @d3
	dec nx
	jr @look
@d3:
	inc nx
@look:
	ld a, nx
	st a, cx
	ld a, ny
	st a, cy
	call peek
	cmp #T_EMPTY
	jz @free
	cmp #T_FOOD
	jz @eat
	cmp #T_BODY
	jnz @dead
	; the tail's cell is free: it moves away this step, unless growing
	ld a, grow
	jnz @dead
	ld x, tail
	ld a, body_x,x
	cmp nx
	jnz @dead
	ld a, body_y,x
	cmp ny
	jnz @dead
	jr @free
@dead:
	jmp game_over
@eat:
	inc grow
	ld a, #1
	st a, ate
	call sfx_eat
	call add_score
@free:
	ld a, grow
	jz @shrink
	dec grow
	jr @advance
@shrink:
	ld x, tail
	ld a, body_x,x
	st a, cx
	ld a, body_y,x
	st a, cy
	ld a, #T_EMPTY
	st a, ct
	call poke
	inc tail
@advance:
	ld x, head          ; the old head becomes body
	ld a, body_x,x
	st a, cx
	ld a, body_y,x
	st a, cy
	ld a, #T_BODY
	st a, ct
	call poke
	inc head
	ld x, head
	ld a, nx
	st a, body_x,x
	st a, cx
	ld a, ny
	st a, body_y,x
	st a, cy
	ld a, #T_HEAD
	st a, ct
	call poke
	ld a, ate
	jz @done
	ld a, #0
	st a, ate
	call place_food
@done:
	ret

game_over:
	ld a, #$0f          ; a crash of noise
	st a, NOISE_VOLUME
	ld a, #$80          ; fading over 30 frames
	st a, NOISE_SHAPE
	ld a, #10
	st a, NOISE_RATE
	st a, NOISE_HI
	ld a, #<tune_over
	ld x, #>tune_over
	call start_tune
	ld a, #<txt_over
	st a, str
	ld a, #>txt_over
	st a, str+1
	ld a, #8
	st a, cy
	ld a, #5
	st a, cx
	call print
	call print_press_start
	ld a, #STATE_OVER
	st a, state
	ret

; score + 1, faster every 5 points
add_score:
	ld x, #2
@digit:
	inc score,x
	ld a, score,x
	cmp #10
	jnz @carried
	ld a, #0
	st a, score,x
	dec x
	jnn @digit
@carried:
	ld a, score+2
	jz @faster
	cmp #5
	jnz @show
@faster:
	ld a, speed
	cmp #TOP_SPEED + 1
	jc @show
	dec speed
@show:
	jmp draw_score

draw_score:
	ld a, #0
	call row_ptr
	ld x, #0
	ld y, #7
@digit:
	ld a, score,x
	add #'0'
	st a, [ptr],y
	inc y
	inc x
	cmp x, #3
	jnz @digit
	ret

; food on a random empty cell inside the walls
place_food:
	ld a, RANDOM
	and #31
	cmp #18
	jnc place_food
	add #1
	st a, cx
@row:
	ld a, RANDOM
	and #15
	cmp #12
	jnc @row
	add #2
	st a, cy
	call peek
	cmp #T_EMPTY
	jnz place_food
	ld a, #T_FOOD
	st a, ct
	jmp poke

; --- sound ---

sfx_eat:
	ld a, #$1c          ; duty 25%, volume 12
	st a, SND0_VOLUME
	ld a, #$40          ; fades out in 12 frames
	st a, SND0_SHAPE
	ld a, #<E6
	st a, SND0_PERIOD
	ld a, #>E6
	st a, SND0_HI
	ret

; plays the tune at X:A on pulse 1, one note per entry
start_tune:
	st a, tune_ptr
	st x, tune_ptr+1
	ld a, #0
	st a, tune_wait
	ret

; once a frame: the next note when the current one is over.
; A note is .word period, .byte frames; a period high byte of $ff ends.
tune_tick:
	ld a, tune_ptr+1
	jz @out
	ld a, tune_wait
	jz @note
	dec tune_wait
@out:
	ret
@note:
	ld y, #1
	ld a, [tune_ptr],y
	cmp #$ff
	jz @end
	mov x, a
	ld y, #2
	ld a, [tune_ptr],y
	st a, tune_wait
	dec tune_wait       ; this frame is the first
	ld y, #0
	ld a, [tune_ptr],y
	st a, tmp
	ld a, #$2a          ; duty 50%, volume 10
	st a, SND1_VOLUME
	ld a, #0
	st a, SND1_SHAPE
	ld a, tmp
	st a, SND1_PERIOD
	st x, SND1_HI       ; starts the note
	ld a, tune_ptr
	add #3
	st a, tune_ptr
	ld a, tune_ptr+1
	adc #0
	st a, tune_ptr+1
	ret
@end:
	ld a, #0
	st a, tune_ptr+1
	st a, SND1_VOLUME
	ret

tune_start:
	.word C5
	.byte 5
	.word E5
	.byte 5
	.word G5
	.byte 5
	.word C6
	.byte 10
	.word $ff00
tune_over:
	.word G4
	.byte 8
	.word REST
	.byte 2
	.word E4
	.byte 8
	.word REST
	.byte 2
	.word C4
	.byte 20
	.word $ff00

; --- the map ---

; ptr = the start of row A
row_ptr:
	mov x, a
	ld a, row_lo,x
	st a, ptr
	ld a, row_hi,x
	st a, ptr+1
	ret

; A = the tile at (cx, cy)
peek:
	ld a, cy
	call row_ptr
	ld y, cx
	ld a, [ptr],y
	ret

; the tile ct at (cx, cy)
poke:
	ld a, cy
	call row_ptr
	ld y, cx
	ld a, ct
	st a, [ptr],y
	ret

; the zero-terminated text at str, from (cx, cy)
print:
	ld a, cy
	call row_ptr
	ld a, ptr
	add cx
	st a, ptr
	ld a, ptr+1
	adc #0
	st a, ptr+1
	ld y, #0
@next:
	ld a, [str],y
	jz @done
	st a, [ptr],y
	inc y
	jr @next
@done:
	ret

clear:
	ld a, #T_EMPTY
	ld x, #0
@cell:                  ; the whole 32x32 map
	st a, MAP,x
	st a, MAP+256,x
	st a, MAP+512,x
	st a, MAP+768,x
	inc x
	jnz @cell
	ret

draw_walls:
	ld a, #1
	call row_ptr
	call @line
	ld a, #14
	call row_ptr
	call @line
	ld a, #2
	st a, cy
@sides:
	ld a, cy
	call row_ptr
	ld a, #T_WALL
	ld y, #0
	st a, [ptr],y
	ld y, #19
	st a, [ptr],y
	inc cy
	ld a, cy
	cmp #14
	jnz @sides
	ret
@line:
	ld a, #T_WALL
	ld y, #19
@cell:
	st a, [ptr],y
	dec y
	jnn @cell
	ret

row_lo:
	.byte <(MAP+0*32), <(MAP+1*32), <(MAP+2*32), <(MAP+3*32), <(MAP+4*32)
	.byte <(MAP+5*32), <(MAP+6*32), <(MAP+7*32), <(MAP+8*32), <(MAP+9*32)
	.byte <(MAP+10*32), <(MAP+11*32), <(MAP+12*32), <(MAP+13*32), <(MAP+14*32)
row_hi:
	.byte >(MAP+0*32), >(MAP+1*32), >(MAP+2*32), >(MAP+3*32), >(MAP+4*32)
	.byte >(MAP+5*32), >(MAP+6*32), >(MAP+7*32), >(MAP+8*32), >(MAP+9*32)
	.byte >(MAP+10*32), >(MAP+11*32), >(MAP+12*32), >(MAP+13*32), >(MAP+14*32)

txt_snake: .byte "SNAKE", 0
txt_start: .byte "PRESS START", 0
txt_score: .byte "SCORE", 0
txt_over:  .byte "GAME OVER", 0

nothing:
	reti

.org $fffa
	.word nothing, reset, reset

; --- tiles ---
.section chr

.tile T_WALL
dddddd3d
dddddd3d
dddddd3d
33333333
dd3ddddd
dd3ddddd
dd3ddddd
33333333

.tile T_BODY
.888888.
87777778
87777778
87777778
87777778
87777778
87777778
.888888.

.tile T_HEAD
.888888.
87777778
87177178
87077078
87777778
87777778
87777778
.888888.

.tile T_FOOD
....7...
...7....
.44.444.
44444444
44444414
44444444
.444444.
..4444..

.tile '0'
.11111..
11...11.
11..111.
11.1.11.
111..11.
11...11.
.11111..
........
.tile '1'
...11...
..111...
...11...
...11...
...11...
...11...
.111111.
........
.tile '2'
.11111..
11...11.
.....11.
...111..
.111....
11......
1111111.
........
.tile '3'
.11111..
11...11.
.....11.
..1111..
.....11.
11...11.
.11111..
........
.tile '4'
....11..
...111..
..1111..
.11.11..
1111111.
....11..
....11..
........
.tile '5'
1111111.
11......
111111..
.....11.
.....11.
11...11.
.11111..
........
.tile '6'
..1111..
.11.....
11......
111111..
11...11.
11...11.
.11111..
........
.tile '7'
1111111.
.....11.
....11..
...11...
..11....
..11....
..11....
........
.tile '8'
.11111..
11...11.
11...11.
.11111..
11...11.
11...11.
.11111..
........
.tile '9'
.11111..
11...11.
11...11.
.111111.
.....11.
....11..
.1111...
........

.tile 'A'
..111...
.11.11..
11...11.
11...11.
1111111.
11...11.
11...11.
........
.tile 'C'
.11111..
11...11.
11......
11......
11......
11...11.
.11111..
........
.tile 'E'
1111111.
11......
11......
111111..
11......
11......
1111111.
........
.tile 'G'
.11111..
11...11.
11......
11.1111.
11...11.
11...11.
.111111.
........
.tile 'K'
11...11.
11..11..
11.11...
1111....
11.11...
11..11..
11...11.
........
.tile 'M'
11...11.
111.111.
1111111.
11.1.11.
11...11.
11...11.
11...11.
........
.tile 'N'
11...11.
111..11.
1111.11.
11.1111.
11..111.
11...11.
11...11.
........
.tile 'O'
.11111..
11...11.
11...11.
11...11.
11...11.
11...11.
.11111..
........
.tile 'P'
111111..
11...11.
11...11.
111111..
11......
11......
11......
........
.tile 'R'
111111..
11...11.
11...11.
111111..
11.11...
11..11..
11...11.
........
.tile 'S'
.11111..
11...11.
11......
.11111..
.....11.
11...11.
.11111..
........
.tile 'T'
11111111
...11...
...11...
...11...
...11...
...11...
...11...
........
.tile 'V'
11...11.
11...11.
11...11.
11...11.
.11.11..
..111...
...1....
........
