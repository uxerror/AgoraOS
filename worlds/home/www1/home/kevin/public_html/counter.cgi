#!/bin/sh
# Kevin's visitor counter. It keeps the number in counter.txt.
n=0
if test -f counter.txt; then
  n=`cat counter.txt`
fi
n=$((n + 1))
echo $n > counter.txt
echo "Content-Type: text/html"
echo
echo "<html><head><title>Visitor counter</title></head><body bgcolor=\"#000000\" text=\"#00ff00\">"
echo "<h1>You are visitor number $n!!</h1>"
echo "<p><a href=\"index.html\">back to my page</a></p></body></html>"
