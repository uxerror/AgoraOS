#!/bin/sh
echo "Content-Type: text/html"
echo
echo "<html><head><title>LanLink: What is my IP?</title></head><body bgcolor=\"#ffffff\">"
echo "<h2>Your connection</h2>"
echo "<p>You are coming from <b>$REMOTE_ADDR</b>.</p>"
echo "<p>Your browser says it is: <tt>$HTTP_USER_AGENT</tt></p>"
echo "<p><a href=\"/\">Back to LanLink</a></p>"
echo "</body></html>"
