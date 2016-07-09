#!/usr/bin/env tclsh8.6
#

proc main {{port 8080}} {
    variable MYPORT
    set MYPORT $port
    socket -server {go accept} $MYPORT
    log "listening on $MYPORT"
    # FIXME: stunnel https
    vwait forever
}

namespace eval util {
    proc yieldm args {yieldto string cat {*}$args}

    proc finally {script} {
        tailcall trace add variable :#finally#: unset [list apply [list args $script]]
    }

    proc go {args} {
        variable :gonum
        incr :gonum
        tailcall coroutine goro${:gonum} {*}$args
    }

    proc timestamp {} {
        clock format [clock seconds] -format "%H:%M:%S"
    }
    proc log {args} {
        puts stderr "[timestamp] $args"
    }
    namespace export *
}
namespace import util::*

proc serve_http {chan scheme host port path} {
    log "Serving HTTP"
    if {$path eq "/proxy.pac"} {
        puts $chan "HTTP/1.1 200 OK"
        puts $chan "Connection: close"  ;# not _strictly_ required, but be sure
        puts $chan "Content-Type: text/javascript"
        puts $chan ""
        # FIXME: this can be generated more cleverly, but have to be stunnel-aware
        puts $chan "function FindProxyForURL(u,h){return \"HTTPS localhost:8443\";}"
    } else {
        puts $chan "HTTP/1.1 404 Not Found"
        puts $chan "Connection: close"
        puts $chan "Content-Type: text/plain"
        puts $chan ""
        puts $chan "No such thing here.  Try /proxy.pac"
    }
}

proc accept {chan chost cport} {
    variable MYPORT
    log "$chan: New connection from $chost:$cport"
    chan configure $chan -blocking 0 -buffering line -translation crlf -encoding iso8859-1

    finally [list catch [list close $chan]]

    chan even $chan readable [info coroutine]
    yieldm
    gets $chan request

    set preamble ""
    while {[yield; gets $chan line] > 0} {
        append preamble $line\n
    }
    chan even $chan readable ""
    if {![regexp {^([A-Z]+) (.*) (HTTP/.*)$} $request -> verb dest httpver]} {
        throw {PROXY BAD_REQUEST} "Bad request: $request"
    }

    set is_http [regexp {^/.*$} $dest]  ;# for transparent proxying, or acting as an HTTP server
    if {$is_http} {
        set scheme "http"   ;# because stunnel is invisible
        set path $dest
        if {![regexp -line {^Host: (.*)(?::(.*))$} $preamble -> host port]} {
            throw {PROXY HTTP BAD_HOST} "Bad Host header!"
        }
    } elseif {[regexp {^(\w+)://\[([^\]/ ]+)\](?::(\d+))?(.*)$} $dest -> scheme host port path]} {
        # IPv6 URL
    } elseif {[regexp {^(\w+)://([^:/ ]+)(?::(\d+))?(.*)$} $dest -> scheme host port path]} {
        # normal URL
    } elseif {[regexp {^([^:/ ]+)(?::(\d+))?$} $dest -> host port]} {
        # CONNECT-style host:port
    } elseif {[regexp {^\[([^\]/ ]+)\](?::(\d+))?$} $dest -> host port]} {
        # CONNECT-style host:port IPv6
    } else {
        throw {PROXY BAD_URL} "Bad URL: $dest"
    }

    # divine the port, if blank
    if {$port eq ""} {
        try {
            set default_ports {http 80 https 443 ftp 21}    ;# this should come from a smarter registry, but here's enough
            set port [dict get $default_ports $scheme]
        } on error {} {
            set port 80
            log "$chan: Using :80 for scheme {$scheme}"
        }
    }

    if {$is_http && 0} {
        # FIXME: transparently proxy this sometimes
        serve_http $chan $scheme $host $port $path
        return
    } elseif {$host in {127.0.0.1 localhost ::1} && $port eq $MYPORT} {
        # NOTE: cannot tailcall here, because that will close the channel!
        serve_http $chan $scheme $host $port $path
        return
    }

    log "$chan: Trying $verb $host:$port"
    set upchan [socket -async $host $port]  ;# FIXME: synchronous DNS blocks :(
    yieldto chan event $upchan writable [info coroutine]
    chan event $upchan writable ""
    set err [chan configure $upchan -error]
    if {$err ne ""} {
        log "$chan: Connect error: $err"
        # FIXME: smarter responses
        puts $chan "$httpver 502 Bad Gateway"
        puts $chan "Content-type: text/plain"
        puts $chan ""
        puts $chan "Error connecting to $host port $port:"
        puts $chan "  $err"
        return
    }
    finally [list catch [list close $upchan]]

    chan configure $upchan -blocking 0 -buffering line -translation crlf -encoding iso8859-1

    if {$verb eq "CONNECT"} {
        # for CONNECT, we need to synthesise a response:
        puts $chan "$httpver 200 OK"
        puts $chan ""
    } else {
        # else, forward the request headers:
        puts $upchan $request
        puts $upchan $preamble  ;# extra newline is wanted here!
    }

    chan configure $chan   -buffering none -translation binary
    chan configure $upchan -buffering none -translation binary
    chan copy $chan $upchan -command [info coroutine]
    chan copy $upchan $chan -command [info coroutine]

    # wait for one chan to close:
    yieldm
    if {[chan eof $chan]} {     ;# this would be the wrong test if TCP supported tip#332 !
        log "$chan: Client abandoned keepalive"
        #close $upchan  ;# [finally] will do this for us
    } else {
        # wait until we're done sending to the client
        yieldm
    }
    log "$chan: Done"
}

main {*}$argv
