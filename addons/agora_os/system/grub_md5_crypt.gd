extends AgoraProgram
## grub-md5-crypt: asks for a password twice and prints its MD5 hash for a
## "password --md5" line in /boot/grub/menu.lst.


func summary() -> String:
	return "encrypt a password in MD5 format for GRUB"


func main(p: AgoraProcess) -> int:
	var tty := p.tty
	var first: Variant = await _ask(p, tty, "Password: ")
	if first == null:
		return 1
	var second: Variant = await _ask(p, tty, "Retype password: ")
	if second == null or second != first:
		return p.fail("\nSorry, passwords do not match.", 1)
	var salt := ""
	for i in 8:
		salt += AgoraGrub.ITOA64[randi() % 64]
	p.outln(AgoraGrub.md5_crypt(str(first), salt))
	return 0


func _ask(p: AgoraProcess, tty: AgoraTty, prompt: String) -> Variant:
	p.out(prompt)
	if tty:
		tty.echo = false
	var line: Variant = await p.read_line()
	if tty:
		tty.echo = true
	p.outln()
	return line
