; Gem Hopper for the NConsole: a side-scrolling platform game.
;
; Run and jump through two levels, pick up gems, stomp beetles, avoid
; spikes and pits, and reach the star at the end.
;
; How it works:
; - Each level is 128 columns x 14 rows of ASCII art in its own program
;   bank (level 1 in bank 1, level 2 in bank 2), read through the window at
;   $8000. The character is the tile: '#' grass, '%' dirt, '=' stone,
;   'o' gem, '^' spikes, '*' the way out, '&' a bush, '(' ')' a cloud,
;   'b' a beetle (it becomes a sprite).
; - The background map is 32 columns wide; the camera only moves forward
;   and each new column is copied in just before it scrolls into view,
;   over one that has left the screen. Collisions read the map in video RAM.
; - Row 0 is the status bar, fixed with FIXROWS.
; - Positions are in pixels; the vertical speed is 8.8 fixed point.
; - Music: a melody on pulse 1 and a bass line on the triangle, played
;   by a small two-voice note player; effects on pulse 0 and noise.

.title "Gem Hopper"
.prgbanks 4                 ; banks 1-2 levels, bank 3 the code

; --- hardware ---
VCTRL   = $3000
BGCOLOR = $3001
SCROLLX = $3002
FIXROWS = $3004
PRGBANK = $3008
PAD1    = $3010
FRAME   = $3020
MAP     = $2000
SPR     = $2400             ; y, x, tile, attributes

SND0_PERIOD = $3030
SND0_HI     = $3031
SND0_VOLUME = $3032
SND0_SHAPE  = $3033
VOICE_BASE  = $3034         ; pulse 1 (voice 0), triangle (voice 4)
NOISE_RATE  = $303c
NOISE_HI    = $303d
NOISE_VOLUME = $303e
NOISE_SHAPE = $303f

BTN_RIGHT = $08
BTN_LEFT  = $04
BTN_A     = $10
BTN_B     = $20
BTN_START = $80

; --- the world ---
LEVEL_DATA = $8000
LEVEL_W    = 128
LEVEL_ROWS = 14
LAST_LEVEL = 2
CAM_MAX    = LEVEL_W * 8 - 160
MAX_BUGS   = 4

T_EMPTY  = ' '
T_GRASS  = '#'
T_DIRT   = '%'
T_STONE  = '='
T_GEM    = 'o'
T_SPIKE  = '^'
T_EXIT   = '*'
T_BEETLE = 'b'

HERO_STAND = 1
HERO_WALK  = 2
HERO_JUMP  = 3
BUG_A      = 4
BUG_B      = 5
BUG_FLAT   = 6
HERO_DEAD  = 7

GRAVITY  = $38              ; 0.22 pixels per frame, per frame
JUMP     = $fc              ; -4.0 pixels per frame
BOUNCE   = $fd              ; -3.0, off a beetle
MAX_FALL = 4

ST_TITLE = 0
ST_PLAY  = 1
ST_DYING = 2
ST_CLEAR = 3
ST_OVER  = 4
ST_WIN   = 5

; notes: CLOCK / (16 * frequency) - 1
REST = 0
C3 = 854
D3 = 761
F3 = 640
G3 = 570
A3 = 507
C4 = 427
E4 = 338
G4 = 284
C5 = 213
D5 = 189
E5 = 169
F5 = 159
G5 = 142
A5 = 126
C6 = 106
E6 = 84

; --- variables ---
.section ram
ptr:       .res 2
src:       .res 2
dst:       .res 2
str:       .res 2
tune:      .res 2
cx:        .res 1
cy:        .res 1
tmp:       .res 1
tmp2:      .res 1
state:     .res 1
timer:     .res 1
level:     .res 1
lives:     .res 1
gems:      .res 2           ; tens, ones
pad_prev:  .res 1
pad_new:   .res 1
px_l:      .res 1           ; hero: world x
px_h:      .res 1
py:        .res 1           ; screen y, and its fraction
pyf:       .res 1
vy_l:      .res 1           ; vertical speed, 8.8
vy_h:      .res 1
on_ground: .res 1
jumping:   .res 1           ; rising from a jump (not a bounce)
facing:    .res 1           ; 0 right, 1 left
speed:     .res 1
cam_l:     .res 1
cam_h:     .res 1
next_col:  .res 1           ; the next level column to copy in
tx_l:      .res 1           ; tile_at: world x and screen y
ty:        .res 1
k:         .res 1
ex_l:      .res MAX_BUGS    ; beetles
ex_h:      .res MAX_BUGS
ey:        .res MAX_BUGS
edir:      .res MAX_BUGS    ; 1 left, 0 right
est:       .res MAX_BUGS    ; 0 none, 1 walking, 2 squashed
etimer:    .res MAX_BUGS
; the note player: voice 0 (pulse 1) and voice 4 (triangle)
tune_lo:   .res 5
tune_hi:   .res 5
loop_lo:   .res 5
loop_hi:   .res 5
tune_wait: .res 5
note_hi:   .res 1

; --- the code, in the last bank ---
.section rom
.org $c000

reset:
	ld a, #$03              ; background and sprites
	st a, VCTRL
	ld a, #9                ; sky blue
	st a, BGCOLOR
	ld a, #1                ; the status bar stays put
	st a, FIXROWS
	ld a, #0
	st a, pad_prev
	call title_screen

main:
	wait
	call tune_tick
	call read_pad
	ld a, state
	cmp #ST_PLAY
	jnz @not_play
	call play_frame
	jmp main
@not_play:
	cmp #ST_DYING
	jnz @not_dying
	call dying_frame
	jmp main
@not_dying:
	cmp #ST_CLEAR
	jnz @menu
	call clear_frame
	jmp main
@menu:                      ; title, game over, the end: start plays
	ld a, pad_new
	and #BTN_START
	jz main
	call new_game
	jmp main

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

; --- screens ---

title_screen:
	call blank_screen
	ld a, #<txt_title
	ld x, #>txt_title
	ld y, #5
	call print_center
	ld a, #<txt_start
	ld x, #>txt_start
	ld y, #9
	call print_center
	; a strip of ground with the hero on it
	ld x, #0
@ground:
	ld a, #T_GRASS
	st a, MAP + 13 * 32,x
	ld a, #T_DIRT
	st a, MAP + 14 * 32,x
	inc x
	cmp x, #20
	jnz @ground
	ld a, #96
	st a, SPR
	ld a, #76
	st a, SPR+1
	ld a, #HERO_STAND
	st a, SPR+2
	ld a, #0
	st a, SPR+3
	ld a, #ST_TITLE
	st a, state
	ret

game_over:
	call stop_music
	call blank_screen
	ld a, #<txt_over
	ld x, #>txt_over
	ld y, #6
	call print_center
	ld a, #<txt_start
	ld x, #>txt_start
	ld y, #9
	call print_center
	ld a, #ST_OVER
	st a, state
	ret

win_screen:
	call blank_screen
	ld a, #<txt_win
	ld x, #>txt_win
	ld y, #5
	call print_center
	ld a, #<txt_gems
	st a, str
	ld a, #>txt_gems
	st a, str+1
	ld a, #7
	st a, cx
	ld a, #7
	st a, cy
	call print
	ld a, #12
	st a, cx
	call print_gems
	ld a, #<txt_start
	ld x, #>txt_start
	ld y, #10
	call print_center
	ld a, #ST_WIN
	st a, state
	ret

; a clean screen: no scroll, no sprites, an empty map
blank_screen:
	ld a, #0
	st a, SCROLLX
	call hide_sprites
	jmp clear_map

new_game:
	ld a, #3
	st a, lives
	ld a, #1
	st a, level
	ld a, #0
	st a, gems
	st a, gems+1
	jmp start_level

start_level:
	ld a, level
	st a, PRGBANK           ; level n lives in bank n
	call blank_screen
	call draw_status
	ld a, #0
	st a, cam_l
	st a, cam_h
	st a, next_col
	ld x, #0
@bugs:
	st a, est,x
	inc x
	cmp x, #MAX_BUGS
	jnz @bugs
@fill:                      ; the first 32 columns
	call draw_next_col
	ld a, next_col
	cmp #32
	jnz @fill
	ld a, #16               ; the hero at column 2, on the ground
	st a, px_l
	ld a, #0
	st a, px_h
	st a, pyf
	st a, vy_l
	st a, vy_h
	st a, facing
	st a, on_ground
	ld a, #88
	st a, py
	ld a, #ST_PLAY
	st a, state
	jmp start_music

; --- playing ---

play_frame:
	; jump
	ld a, pad_new
	and #BTN_A
	jz @no_jump
	ld a, on_ground
	jz @no_jump
	ld a, #JUMP
	st a, vy_h
	ld a, #0
	st a, vy_l
	ld a, #1
	st a, jumping
	call sfx_jump
@no_jump:
	call move_x
	call move_y
	; fell into a pit: 120 <= y < 160 (above the screen wraps to 248+)
	ld a, py
	cmp #120
	jc @on_screen
	cmp #160
	jnc @on_screen
	jmp kill_player
@on_screen:
	call check_tiles
	ld a, state
	cmp #ST_PLAY
	jnz @done               ; died or finished the level
	call update_camera
	call update_bugs
	ld a, state
	cmp #ST_PLAY
	jnz @done
	call draw_hero
	call draw_bugs
@done:
	ret

; left and right, one pixel at a time so walls stop us exactly
move_x:
	ld a, #1
	st a, speed
	ld a, pad_prev
	and #BTN_B
	jz @walk
	inc speed               ; running
@walk:
	ld a, pad_prev
	and #BTN_RIGHT
	jz @left
	ld a, #0
	st a, facing
@right_step:
	ld a, px_l
	add #8
	st a, tx_l
	call wall_at
	jnz @stop
	inc px_l
	jnz @right_moved
	inc px_h
@right_moved:
	dec speed
	jnz @right_step
@stop:
	ret
@left:
	ld a, pad_prev
	and #BTN_LEFT
	jz @stop
	ld a, #1
	st a, facing
@left_step:
	ld a, px_l              ; not back past the left edge of the screen
	cmp cam_l
	jnz @left_free
	ld a, px_h
	cmp cam_h
	jz @stop
@left_free:
	ld a, px_l
	sub #1
	st a, tx_l
	call wall_at
	jnz @stop
	ld a, px_l
	sub #1
	st a, px_l
	ld a, px_h
	sbc #0
	st a, px_h
	dec speed
	jnz @left_step
	ret

; A = 1 if column tx_l is solid at the hero's top or bottom
wall_at:
	ld a, py
	st a, ty
	call solid_at
	jnz @yes
	ld a, py
	add #7
	st a, ty
	jmp solid_at
@yes:
	ret

; gravity, the jump's height, landing and bumping heads
move_y:
	ld a, vy_l
	add #GRAVITY
	st a, vy_l
	ld a, vy_h
	adc #0
	st a, vy_h
	jn @rising
	ld a, #0                ; falling: the jump is over
	st a, jumping
	ld a, vy_h
	cmp #MAX_FALL
	jc @apply
	ld a, #MAX_FALL
	st a, vy_h
	ld a, #0
	st a, vy_l
	jr @apply
@rising:                    ; let go of A: a lower jump
	ld a, jumping
	jz @apply
	ld a, pad_prev
	and #BTN_A
	jnz @apply
	ld a, vy_h
	cmp #$ff
	jz @apply
	ld a, #$ff
	st a, vy_h
	ld a, #0
	st a, vy_l
@apply:
	ld a, pyf
	add vy_l
	st a, pyf
	ld a, py
	adc vy_h
	st a, py
	ld a, #0
	st a, on_ground
	ld a, vy_h
	jn @up
	ld a, py                ; falling: the feet
	add #8
	st a, ty
	call floor_at
	jz @free
	ld a, py                ; stand on top of the tile
	add #8
	and #$f8
	sub #8
	st a, py
	ld a, #1
	st a, on_ground
	jr @stopped
@up:
	ld a, py                ; rising: the head
	st a, ty
	call floor_at
	jz @free
	ld a, py
	and #$f8
	add #8
	st a, py
@stopped:
	ld a, #0
	st a, pyf
	st a, vy_l
	st a, vy_h
@free:
	ret

; A = 1 if row ty is solid under the hero's left or right side
floor_at:
	ld a, px_l
	add #1
	st a, tx_l
	call solid_at
	jnz @yes
	ld a, px_l
	add #6
	st a, tx_l
	jmp solid_at
@yes:
	ret

; gems, the way out, spikes
check_tiles:
	ld a, px_l
	add #4
	st a, tx_l
	ld a, py
	add #4
	st a, ty
	call tile_at
	cmp #T_GEM
	jnz @not_gem
	ld a, #T_EMPTY          ; tile_at left ptr and Y on it
	st a, [ptr],y
	call add_gem
	jr @feet
@not_gem:
	cmp #T_EXIT
	jnz @feet
	jmp level_clear
@feet:
	ld a, py
	add #7
	st a, ty
	call tile_at
	cmp #T_SPIKE
	jnz @safe
	jmp kill_player
@safe:
	ret

add_gem:
	call sfx_gem
	inc gems+1
	ld a, gems+1
	cmp #10
	jnz @show
	ld a, #0
	st a, gems+1
	inc gems
	ld a, gems
	cmp #10
	jnz @show
	ld a, #9                ; 99 at most
	st a, gems
	st a, gems+1
@show:
	jmp draw_status

kill_player:
	ld a, #ST_DYING
	st a, state
	ld a, #JUMP
	st a, vy_h
	ld a, #0
	st a, vy_l
	ld a, #100
	st a, timer
	call stop_music
	ld a, #<tune_death
	ld x, #>tune_death
	jmp play_once

; the hero hops up and falls off the screen
dying_frame:
	ld a, vy_l
	add #GRAVITY
	st a, vy_l
	ld a, vy_h
	adc #0
	st a, vy_h
	ld a, pyf
	add vy_l
	st a, pyf
	ld a, py
	adc vy_h
	st a, py
	call draw_hero
	dec timer
	jnz @wait
	dec lives
	jz @over
	jmp start_level
@over:
	jmp game_over
@wait:
	ret

level_clear:
	ld a, #ST_CLEAR
	st a, state
	ld a, #120
	st a, timer
	call stop_music
	ld a, #<txt_clear
	st a, str
	ld a, #>txt_clear
	st a, str+1
	ld a, #15
	st a, cx
	ld a, #0
	st a, cy
	call print
	ld a, #<tune_clear
	ld x, #>tune_clear
	jmp play_once

clear_frame:
	dec timer
	jnz @wait
	inc level
	ld a, level
	cmp #LAST_LEVEL + 1
	jz @won
	jmp start_level
@won:
	jmp win_screen
@wait:
	ret

; --- the camera and the map ---

update_camera:
	ld a, px_l              ; target = x - 64
	sub #64
	st a, tmp
	ld a, px_h
	sbc #0
	jc @scroll              ; near the start
	st a, tmp2
	ld a, tmp               ; only forward
	sub cam_l
	ld a, tmp2
	sbc cam_h
	jc @scroll
	ld a, tmp               ; not past the end
	sub #<CAM_MAX
	ld a, tmp2
	sbc #>CAM_MAX
	jc @move
	ld a, #<CAM_MAX
	st a, tmp
	ld a, #>CAM_MAX
	st a, tmp2
@move:
	ld a, tmp
	st a, cam_l
	ld a, tmp2
	st a, cam_h
@scroll:
	ld a, cam_l
	st a, SCROLLX
	; copy columns in while the camera needs them:
	; next_col <= camera column + 31
	ld a, cam_l
	shr a
	shr a
	shr a
	st a, tmp
	ld a, cam_h
	shl a
	shl a
	shl a
	shl a
	shl a
	or tmp
	add #31
	st a, tmp2
@stream:
	ld a, next_col
	cmp #LEVEL_W
	jnc @done
	ld a, tmp2
	cmp next_col
	jc @done
	call draw_next_col
	jr @stream
@done:
	ret

; copies level column next_col into the map, beetles out as sprites
draw_next_col:
	ld a, next_col
	cmp #LEVEL_W
	jnc @done
	st a, src
	ld a, #>LEVEL_DATA
	st a, src+1
	ld a, next_col
	and #31
	add #32                 ; map row 1
	st a, dst
	ld a, #>MAP
	st a, dst+1
	ld a, #LEVEL_ROWS
	st a, tmp
	ld a, #1
	st a, cy
@row:
	ld y, #0
	ld a, [src],y
	cmp #T_BEETLE
	jnz @put
	call spawn_bug
	ld a, #T_EMPTY
@put:
	ld y, #0
	st a, [dst],y
	ld a, src               ; the next row: 128 bytes on in the level
	add #LEVEL_W
	st a, src
	ld a, src+1
	adc #0
	st a, src+1
	ld a, dst               ; 32 bytes on in the map
	add #32
	st a, dst
	ld a, dst+1
	adc #0
	st a, dst+1
	inc cy
	dec tmp
	jnz @row
	inc next_col
@done:
	ret

clear_map:
	ld a, #T_EMPTY
	ld x, #0
@cell:
	st a, MAP,x
	st a, MAP+256,x
	st a, MAP+512,x
	st a, MAP+768,x
	inc x
	jnz @cell
	ret

hide_sprites:
	ld a, #$f0
	ld x, #0
@s:
	st a, SPR,x
	inc x
	cmp x, #128
	jnz @s
	ret

; A = the tile at world x tx_l (the map wraps every 256 pixels) and
; screen y ty; ptr and Y are left on it. Off the map is empty.
tile_at:
	ld a, ty
	cmp #120
	jnc @empty
	shr a
	shr a
	shr a
	jz @empty               ; the status bar
	mov x, a
	ld a, row_lo,x
	st a, ptr
	ld a, row_hi,x
	st a, ptr+1
	ld a, tx_l
	shr a
	shr a
	shr a
	mov y, a
	ld a, [ptr],y
	ret
@empty:
	ld a, #T_EMPTY
	ret

; A = 1 if the tile at (tx_l, ty) is solid, else 0; flags follow A
solid_at:
	call tile_at
	cmp #T_GRASS
	jz @yes
	cmp #T_DIRT
	jz @yes
	cmp #T_STONE
	jz @yes
	ld a, #0
	ret
@yes:
	ld a, #1
	ret

; --- beetles ---

; a beetle at column next_col, screen row cy
spawn_bug:
	ld x, #0
@find:
	ld a, est,x
	jz @found
	inc x
	cmp x, #MAX_BUGS
	jnz @find
	ret                     ; all busy: this one stays home
@found:
	ld a, #1
	st a, est,x
	st a, edir,x
	ld a, next_col
	shl a
	shl a
	shl a
	st a, ex_l,x
	ld a, next_col
	shr a
	shr a
	shr a
	shr a
	shr a
	st a, ex_h,x
	ld a, cy
	shl a
	shl a
	shl a
	st a, ey,x
	ret

update_bugs:
	ld x, #0
@loop:
	st x, k
	ld a, est,x
	jz @next
	cmp #1
	jz @walking
	dec etimer,x            ; squashed for a moment
	jnz @next
	ld a, #0
	st a, est,x
	jr @next
@walking:
	call bug_walk
	call bug_touch
	ld a, state
	cmp #ST_PLAY
	jnz @out
@next:
	ld x, k
	inc x
	cmp x, #MAX_BUGS
	jnz @loop
@out:
	ret

bug_walk:
	ld x, k
	ld a, ex_l,x            ; gone when 16 pixels left of the screen
	add #16
	st a, tmp
	ld a, ex_h,x
	adc #0
	st a, tmp2
	ld a, tmp
	sub cam_l
	ld a, tmp2
	sbc cam_h
	jnc @alive
	ld a, #0
	st a, est,x
	ret
@alive:
	ld a, FRAME             ; a step every other frame
	and #1
	jz @still
	ld a, ey,x
	st a, ty
	ld a, edir,x
	jz @right
	ld a, ex_l,x            ; left: a wall, or no floor, turns it
	sub #1
	jmp @look
@right:
	ld a, ex_l,x
	add #8
@look:
	st a, tx_l
	call solid_at
	jnz @turn
	ld x, k
	ld a, ey,x
	add #8
	st a, ty
	call solid_at
	jz @turn
	ld x, k
	ld a, edir,x
	jz @step_right
	ld a, ex_l,x
	sub #1
	st a, ex_l,x
	ld a, ex_h,x
	sbc #0
	st a, ex_h,x
	ret
@step_right:
	inc ex_l,x
	jnz @still
	inc ex_h,x
@still:
	ret
@turn:
	ld x, k
	ld a, edir,x
	xor #1
	st a, edir,x
	ret

; the hero meets beetle k: from above it's squashed, otherwise it hurts
bug_touch:
	ld x, k
	ld a, est,x
	cmp #1
	jnz @miss
	ld a, px_l              ; dx = hero - beetle, within -6..6
	sub ex_l,x
	st a, tmp
	ld a, px_h
	sbc ex_h,x
	jz @right_of
	cmp #$ff
	jnz @miss
	ld a, tmp
	cmp #$fa
	jc @miss
	jr @dy
@right_of:
	ld a, tmp
	cmp #7
	jnc @miss
@dy:
	ld a, py                ; dy = hero - beetle
	sub ey,x
	jc @above
	cmp #8
	jnc @miss
	jmp kill_player
@above:
	cmp #$f8
	jc @miss
	ld a, vy_h
	jn @hurt                ; jumping up into it
	ld a, #2
	st a, est,x
	ld a, #20
	st a, etimer,x
	ld a, #BOUNCE
	st a, vy_h
	ld a, #0
	st a, vy_l
	jmp sfx_stomp
@hurt:
	jmp kill_player
@miss:
	ret

; --- sprites ---

draw_hero:
	ld a, py
	st a, SPR
	ld a, px_l
	sub cam_l
	st a, SPR+1
	ld a, facing
	st a, SPR+3
	ld a, state
	cmp #ST_DYING
	jnz @alive
	ld a, #HERO_DEAD
	jr @tile
@alive:
	ld a, on_ground
	jnz @ground
	ld a, #HERO_JUMP
	jr @tile
@ground:
	ld a, pad_prev
	and #BTN_LEFT | BTN_RIGHT
	jz @stand
	ld a, FRAME
	and #8
	jz @stand
	ld a, #HERO_WALK
	jr @tile
@stand:
	ld a, #HERO_STAND
@tile:
	st a, SPR+2
	ret

; beetle k is sprite k + 1
draw_bugs:
	ld x, #0
@loop:
	mov a, x                ; y = its sprite's offset: (k + 1) * 4
	add #1
	shl a
	shl a
	mov y, a
	ld a, est,x
	jz @hide
	ld a, ex_l,x            ; on screen: -8 < x - camera < 160
	sub cam_l
	st a, tmp
	ld a, ex_h,x
	sbc cam_h
	jz @maybe
	cmp #$ff
	jnz @hide
	ld a, tmp
	cmp #$f9
	jc @hide
	jr @show
@maybe:
	ld a, tmp
	cmp #160
	jnc @hide
@show:
	ld a, ey,x
	st a, SPR,y
	ld a, tmp
	st a, SPR+1,y
	ld a, est,x
	cmp #2
	jz @flat
	ld a, FRAME
	and #8
	jz @frame_a
	ld a, #BUG_B
	jr @put
@frame_a:
	ld a, #BUG_A
	jr @put
@flat:
	ld a, #BUG_FLAT
@put:
	st a, SPR+2,y
	ld a, edir,x
	xor #1                  ; drawn facing left
	st a, SPR+3,y
	jr @next
@hide:
	ld a, #$f0
	st a, SPR,y
@next:
	inc x
	cmp x, #MAX_BUGS
	jnz @loop
	ret

; --- text ---

draw_status:
	ld a, #<txt_gems
	st a, str
	ld a, #>txt_gems
	st a, str+1
	ld a, #1
	st a, cx
	ld a, #0
	st a, cy
	call print
	ld a, #6
	st a, cx
	call print_gems
	ld a, #<txt_life
	st a, str
	ld a, #>txt_life
	st a, str+1
	ld a, #9
	st a, cx
	call print
	ld a, lives
	add #'0'
	st a, MAP + 14
	ret

; the two digits of gems at (cx, cy)
print_gems:
	ld a, cy
	call row_ptr
	ld y, cx
	ld a, gems
	add #'0'
	st a, [ptr],y
	inc y
	ld a, gems+1
	add #'0'
	st a, [ptr],y
	ret

; the text at X:A centred on row Y
print_center:
	st a, str
	st x, str+1
	st y, cy
	ld y, #0
@len:
	ld a, [str],y
	jz @counted
	inc y
	jr @len
@counted:
	mov a, y                ; cx = (20 - length) / 2
	st a, tmp
	ld a, #20
	sub tmp
	shr a
	st a, cx
	jmp print

; ptr = the start of map row A
row_ptr:
	mov x, a
	ld a, row_lo,x
	st a, ptr
	ld a, row_hi,x
	st a, ptr+1
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

row_lo:
	.byte <(MAP+0*32), <(MAP+1*32), <(MAP+2*32), <(MAP+3*32), <(MAP+4*32)
	.byte <(MAP+5*32), <(MAP+6*32), <(MAP+7*32), <(MAP+8*32), <(MAP+9*32)
	.byte <(MAP+10*32), <(MAP+11*32), <(MAP+12*32), <(MAP+13*32), <(MAP+14*32)
row_hi:
	.byte >(MAP+0*32), >(MAP+1*32), >(MAP+2*32), >(MAP+3*32), >(MAP+4*32)
	.byte >(MAP+5*32), >(MAP+6*32), >(MAP+7*32), >(MAP+8*32), >(MAP+9*32)
	.byte >(MAP+10*32), >(MAP+11*32), >(MAP+12*32), >(MAP+13*32), >(MAP+14*32)

txt_title: .byte "GEM HOPPER", 0
txt_start: .byte "PRESS START", 0
txt_gems:  .byte "GEMS", 0
txt_life:  .byte "LIFE", 0
txt_clear: .byte "CLEAR", 0
txt_over:  .byte "GAME OVER", 0
txt_win:   .byte "YOU WIN", 0

; --- sound ---

sfx_jump:
	ld a, #$0a              ; duty 12.5%, volume 10
	st a, SND0_VOLUME
	ld a, #$40              ; a quick fade
	st a, SND0_SHAPE
	ld a, #<A5
	st a, SND0_PERIOD
	ld a, #>A5
	st a, SND0_HI
	ret

sfx_gem:
	ld a, #$1c
	st a, SND0_VOLUME
	ld a, #$40
	st a, SND0_SHAPE
	ld a, #<E6
	st a, SND0_PERIOD
	ld a, #>E6
	st a, SND0_HI
	ret

sfx_stomp:
	ld a, #$0c
	st a, NOISE_VOLUME
	ld a, #$40
	st a, NOISE_SHAPE
	ld a, #6
	st a, NOISE_RATE
	st a, NOISE_HI
	ret

start_music:
	ld a, #<music_melody
	ld x, #>music_melody
	ld y, #0
	call start_voice
	ld a, #<music_bass
	ld x, #>music_bass
	ld y, #4
	jmp start_voice

; a tune on voice 0 that plays once, the bass quiet
play_once:
	ld y, #0
	jmp start_voice

stop_music:
	ld a, #0
	st a, tune_hi
	st a, tune_hi+4
	st a, VOICE_BASE+2
	st a, VOICE_BASE+6
	ret

; the tune at X:A on voice Y (0 or 4), looping back to its start
start_voice:
	st a, tune_lo,y
	st a, loop_lo,y
	st x, tune_hi,y
	st x, loop_hi,y
	ld a, #0
	st a, tune_wait,y
	ret

tune_tick:
	ld x, #0
	call voice_tick
	ld x, #4
	jmp voice_tick

; voice X: the next note when the current one is over. A note is
; .word period, .byte frames; a period high byte of $ff ends the tune,
; $fe goes back to its start.
voice_tick:
	ld a, tune_hi,x
	jz @out
	ld a, tune_wait,x
	jz @note
	dec tune_wait,x
@out:
	ret
@note:
	ld a, tune_lo,x
	st a, tune
	ld a, tune_hi,x
	st a, tune+1
	ld y, #1
	ld a, [tune],y
	cmp #$ff
	jz @end
	cmp #$fe
	jz @again
	st a, note_hi
	ld y, #2
	ld a, [tune],y
	st a, tune_wait,x
	dec tune_wait,x         ; this frame is the first
	ld y, #0
	ld a, [tune],y
	st a, VOICE_BASE,x
	ld a, voice_volume,x
	st a, VOICE_BASE+2,x
	ld a, #0
	st a, VOICE_BASE+3,x
	ld a, note_hi
	st a, VOICE_BASE+1,x    ; starts the note
	ld a, tune_lo,x
	add #3
	st a, tune_lo,x
	ld a, tune_hi,x
	adc #0
	st a, tune_hi,x
	ret
@again:
	ld a, loop_lo,x
	st a, tune_lo,x
	ld a, loop_hi,x
	st a, tune_hi,x
	jmp @note
@end:
	ld a, #0
	st a, tune_hi,x
	st a, VOICE_BASE+2,x
	ret

voice_volume:
	.byte $28, 0, 0, 0, $0c     ; pulse 1: duty 50%, volume 8; triangle: 12

; eighth notes are 8 frames
music_melody:
	.word C5
	.byte 8
	.word E5
	.byte 8
	.word G5
	.byte 8
	.word E5
	.byte 8
	.word F5
	.byte 8
	.word A5
	.byte 8
	.word G5
	.byte 16
	.word E5
	.byte 8
	.word G5
	.byte 8
	.word C6
	.byte 8
	.word G5
	.byte 8
	.word A5
	.byte 8
	.word G5
	.byte 8
	.word E5
	.byte 16
	.word D5
	.byte 8
	.word F5
	.byte 8
	.word A5
	.byte 8
	.word F5
	.byte 8
	.word G5
	.byte 8
	.word F5
	.byte 8
	.word E5
	.byte 8
	.word D5
	.byte 8
	.word C5
	.byte 8
	.word E5
	.byte 8
	.word G5
	.byte 8
	.word E5
	.byte 8
	.word D5
	.byte 16
	.word C5
	.byte 16
	.word $fe00

music_bass:
	.word C3
	.byte 16
	.word C3
	.byte 16
	.word F3
	.byte 16
	.word F3
	.byte 16
	.word C3
	.byte 16
	.word C3
	.byte 16
	.word A3
	.byte 16
	.word A3
	.byte 16
	.word D3
	.byte 16
	.word D3
	.byte 16
	.word G3
	.byte 16
	.word G3
	.byte 16
	.word C3
	.byte 16
	.word C3
	.byte 16
	.word G3
	.byte 16
	.word C3
	.byte 16
	.word $fe00

tune_death:
	.word G4
	.byte 6
	.word E4
	.byte 6
	.word C4
	.byte 6
	.word G3
	.byte 24
	.word $ff00

tune_clear:
	.word C5
	.byte 6
	.word E5
	.byte 6
	.word G5
	.byte 6
	.word C6
	.byte 18
	.word G5
	.byte 6
	.word C6
	.byte 30
	.word $ff00

nothing:
	reti

.org $fffa
	.word nothing, reset, reset

; --- the levels, one per bank ---
; 14 rows of 128 columns; the rows are 128 bytes apart.
.bank 1
.org LEVEL_DATA
level1:
	.byte "                                                                                                                              =="
	.byte "    ()                           ()                               ()                                    ()                    =="
	.byte "                  ()                                                                    ()                                    =="
	.byte "                                                  ()                                                                          =="
	.byte "                                    oooo                                          oooo                                        =="
	.byte "                                    ====                                          ====                            o           =="
	.byte "                                                                                                                o             =="
	.byte "             oooo                           ooo     ooooo             ooo                                        ==           =="
	.byte "             ====     oo      =====                 =====                   ====        ====    oo              ===           =="
	.byte "                                                                                                               ====           =="
	.byte "     &   &         &       b             b       &        b oo  ^^ &                  b             &  b      =====       *   =="
	.byte "######################  ####################   #######################   #######################  ##############################"
	.byte "%%%%%%%%%%%%%%%%%%%%%%  %%%%%%%%%%%%%%%%%%%%   %%%%%%%%%%%%%%%%%%%%%%%   %%%%%%%%%%%%%%%%%%%%%%%  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"
	.byte "%%%%%%%%%%%%%%%%%%%%%%  %%%%%%%%%%%%%%%%%%%%   %%%%%%%%%%%%%%%%%%%%%%%   %%%%%%%%%%%%%%%%%%%%%%%  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"

.bank 2
.org LEVEL_DATA
level2:
	.byte "                                                                                                                              =="
	.byte "                        ()                                  ()                                    ()                          =="
	.byte "      ()                                                                      ()                                              =="
	.byte "                                            ()                                                                                =="
	.byte "                                    ooo                             ooo                                                       =="
	.byte "                                    ===                             ===               oooo                        o           =="
	.byte "                      oooo                             ooo                            ====                      o             =="
	.byte "        ooo           ====              oooo           ===                                    oooo               ==           =="
	.byte "        ===                   ====      ====                  ====        ===                 ====              ===           =="
	.byte "              ooo                                                                                              ====           =="
	.byte "    &       ^      b      &b         ^^      b      &b     b      ^^    b     b     ^^    b &       b ooo b   =====       *   =="
	.byte "##############   #############    ##############   ###########    ##############   ###########    ##############################"
	.byte "%%%%%%%%%%%%%%   %%%%%%%%%%%%%    %%%%%%%%%%%%%%   %%%%%%%%%%%    %%%%%%%%%%%%%%   %%%%%%%%%%%    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"
	.byte "%%%%%%%%%%%%%%   %%%%%%%%%%%%%    %%%%%%%%%%%%%%   %%%%%%%%%%%    %%%%%%%%%%%%%%   %%%%%%%%%%%    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"

; --- tiles ---
.section chr

; the hero, facing right
.tile HERO_STAND
..5...5.
..55.55.
.5555555
.5553553
55555544
.5eeee5.
.5eeee5.
..3..3..
.tile HERO_WALK
..5...5.
..55.55.
.5555555
.5553553
55555544
.5eeee5.
.5eeee5.
.3....3.
.tile HERO_JUMP
..5...5.
..55.55.
.5555555
.5553553
55555544
5eeeee5.
.5eeee5.
3.....3.
.tile HERO_DEAD
..5...5.
..55.55.
.5555555
.5515515
55555544
.5eeee5.
.5eeee5.
..3..3..

; the beetle, facing left
.tile BUG_A
........
..bbbb..
.b1bbbb.
bbbbbbbb
bbbbbbbb
.bbbbbb.
.3..3.3.
3..3..3.
.tile BUG_B
........
..bbbb..
.b1bbbb.
bbbbbbbb
bbbbbbbb
.bbbbbb.
3..3..3.
.3..3.3.
.tile BUG_FLAT
........
........
........
........
........
..bbbb..
.bbbbbb.
b3b33b3b

.tile T_GRASS
7.7..7.7
77777777
78777787
88888888
dd8ddd8d
dddddddd
dd3ddddd
ddddd3dd
.tile T_DIRT
dddddddd
dd3ddddd
ddddd3dd
dddddddd
d3dddddd
dddddd3d
dddddddd
ddd3dddd
.tile '&'
........
........
........
..77.7..
.777777.
7778777.
77777877
.888888.
.tile '('
........
....111.
..11111.
.1111111
11111111
11111111
.1111111
........
.tile ')'
........
........
1.......
111.....
11111...
111111..
11111...
........
.tile T_EXIT
...66...
...66...
66666666
.665566.
..6666..
.66..66.
.6....6.
........
.tile T_STONE
12222223
21222223
22222223
33333333
22231222
22232222
22232222
33333333
.tile T_SPIKE
........
...1....
...2...1
..122..2
..222.12
.1222.22
.2222222
33333333
.tile T_GEM
...ff...
..f1ff..
.f1ffff.
ffffffff
.ffffff.
..ffff..
...ff...
........

; letters missing from the Snake font
.tile 'F'
1111111.
11......
11......
111111..
11......
11......
11......
........
.tile 'H'
11...11.
11...11.
11...11.
1111111.
11...11.
11...11.
11...11.
........
.tile 'I'
.111111.
...11...
...11...
...11...
...11...
...11...
.111111.
........
.tile 'L'
11......
11......
11......
11......
11......
11......
1111111.
........
.tile 'U'
11...11.
11...11.
11...11.
11...11.
11...11.
11...11.
.11111..
........
.tile 'W'
11...11.
11...11.
11...11.
11.1.11.
1111111.
111.111.
11...11.
........
.tile 'Y'
11...11.
11...11.
.11.11..
..111...
...11...
...11...
...11...
........

; the font, shared with Snake
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
