#!/usr/bin/env tclsh8.6
#

proc main {{port 8080}} {
    # FIXME: support a bind address/port registry
    variable MYPORTS
    lappend MYPORTS $port
    socket -server {accept proxy} $port
    log "listening on $port"
    # FIXME: stunnel https
    if {[file exists stunnel.sh]} {
        variable SSL
        set sslport [expr {$port + 443 - 80}]
        lappend MYPORTS $sslport
        set SSL [open "|./stunnel.sh $sslport $port" w]
        finally [list close $SSL]   ;# harhar
        log "listening (TLS) on $sslport"
        vwait forever
    }
}

namespace eval util {
    proc yieldm args {yieldto string cat {*}$args}

    proc finally {script} {
        tailcall trace add variable :#finally#: unset [list apply [list args $script]]
    }

    proc timestamp {} {
        clock format [clock seconds] -format "%H:%M:%S"
    }

    proc log {args} {
        puts stderr "[timestamp] [list [info coroutine]] $args"
    }

    proc dedent {text} {
        set text [string trimleft $text \n]
        set text [string trimright $text \ ]
        regexp -line {^ +} $text space
        regsub -line -all ^$space $text ""
    }

    namespace export *
}
namespace import util::*

proc serve_http {chan scheme host port path} {
    log "Serving HTTP" $path
    if {$path eq "/proxy.pac"} {
        puts $chan "HTTP/1.1 200 OK"
        puts $chan "Connection: close"  ;# not _strictly_ required, but be sure
        puts $chan "Content-Type: text/javascript"
        puts $chan ""
        # FIXME: this can be generated more cleverly, but have to be stunnel-aware
        variable MYPORTS
        variable SSL
        if {[info exists SSL] && $SSL ne ""} {
            set port [lindex $MYPORTS 1]
            puts $chan "function FindProxyForURL(u,h){return \"HTTPS $host:$port\";}"
        } else {
            set port [lindex $MYPORTS 0]
            puts $chan "function FindProxyForURL(u,h){return \"PROXY $host:$port\";}"
        }
    } else {
        puts $chan "HTTP/1.1 404 Not Found"
        puts $chan "Connection: close"
        puts $chan "Content-Type: text/plain"
        puts $chan ""
        puts $chan "No such thing here.  Try /proxy.pac"
    }
}

namespace eval filter {
    # TODO: a bit of sugar
    proc deproxify {_request _headers} {    ;# turn request into path-only and create Host: header
                                            ;# most servers don't actually care, but rfc2616 5.1.2 MUST
                                            ;# and paste.tclers.tk cares
        upvar 1 $_request request
        upvar 1 $_headers headers

        # FIXME: code duplication
        if {![regexp {^([A-Z]+) (.*) (HTTP/.*)$} $request -> verb dest httpver]} {
            return
        }
        if {[regexp {^(\w+)://\[([^\]/ ]+)\](?::(\d+))?(.*)$} $dest -> scheme host port path]} {
            # IPv6 URL
        } elseif {[regexp {^(\w+)://([^:/ ]+)(?::(\d+))?(.*)$} $dest -> scheme host port path]} {
            # normal URL
        } else {
            return  ;# nothing I can handle here!
        }
        if {$scheme ne "http"} return   ;# nothing I can handle here!
        if {$port eq 80} {set port ""}
        if {[regexp -line {^Host: (.*)(?::(.*))$} $headers -> h_host h_port]} {
            if {$h_port eq 80} {set h_port ""}
            if {$h_host ne $host || $h_port ne $port} {
                throw {PROXY ILLEGAL HEADER} "Illegal host header! $h_host:$h_port"
            }
            regsub -line {^Host: (.*)\n} $headers "" headers
        }
        set request "$verb $path $httpver"
        set headers "Host: $host:$port\n$headers"
    }

    proc nokeepalive {_request _headers} {
        upvar 1 $_request request
        upvar 1 $_headers headers
        regsub -line {^Connection: (.*)\n} $headers "" headers
        append headers "Connection: close\n"
    }

    proc basicauth {_request _headers} {
        upvar 1 $_request request
        upvar 1 $_headers headers
        if {![regexp -line {^Proxy-Authorization: Basic (.*)$} $headers -> creds]} {
            return -code return [dedent {
                HTTP/1.1 407 Proxy Authentication Required
                Proxy-Authenticate: Basic realm="Tiny Proxy"
                Connection: close
                
            }]
        }
        set creds [binary decode base64 $creds]
        if {![regexp {^(.*?):(.*)$} $creds -> user pass]} {
            throw {PROXY AUTH BAD}
        }
        log "Authenticated: $user $pass"
        regsub -line {^Proxy-Authorization: Basic (.*)\n} $headers "" headers
    }
}

namespace eval Clients {}

proc accept {handler chan host port} {
    set coname [string map {: _} $host]:$port
    coroutine Clients::$coname $handler $chan $host $port
}

proc proxy {chan chost cport} {
    variable MYPORTS
    finally [list catch [list close $chan]]

    log "New connection: $chan"
    chan configure $chan -blocking 0 -buffering line -translation crlf -encoding iso8859-1

    chan event $chan readable [info coroutine]

    yield; gets $chan request

    if {$request eq "" && [chan eof $chan]} {
        log "Client closed before sending request"
        return
    }

    set preamble ""
    while {[yield; gets $chan line] > 0} {
        append preamble $line\n
    }

    chan even $chan readable ""

    if {![regexp {^([A-Z]+) (.*) (HTTP/.*)$} $request -> verb dest httpver]} {
        throw {PROXY BAD_REQUEST} "Bad request: [list $request]"
    }

    set is_http [regexp {^/.*$} $dest]  ;# for transparent proxying, or acting as an HTTP server
    if {$is_http} {
        set scheme "http"   ;# because stunnel is invisible
        set path $dest
        if {![regexp -line {^Host: (.*?)(?::(\d+))?$} $preamble -> host port]} {
            throw {PROXY HTTP BAD_HOST} "Bad Host header!"
        }
    } elseif {[regexp {^(\w+)://\[([^\]/ ]+)\](?::(\d+))?(.*)$} $dest -> scheme host port path]} {
        # IPv6 URL
    } elseif {[regexp {^(\w+)://([^:/ ]+)(?::(\d+))?(.*)$} $dest -> scheme host port path]} {
        # normal URL
    } elseif {[regexp {^([^:/ ]+)(?::(\d+))?$} $dest -> host port]} {
        set scheme ""
        # CONNECT-style host:port
    } elseif {[regexp {^\[([^\]/ ]+)\](?::(\d+))?$} $dest -> host port]} {
        set scheme ""
        # CONNECT-style host:port IPv6
    } else {
        throw [list PROXY BAD_URL $dest] "Invalid URL format: [list $dest]"
    }

    if {$scheme ni {"" "http"}} {
        throw [list PROXY BAD_SCHEME $scheme] "Unknown URL scheme [list $scheme]; only HTTP supported!"
    }

    # divine the port, if blank
    if {$port eq ""} {
        set port 80
    }

    # FIXME: don't simply check $is_http because we might want to be a transparent proxy
    # FIXME: make this a filter
    if {$is_http || ($host in {127.0.0.1 localhost ::1} && $port in $MYPORTS)} {
        serve_http $chan $scheme $host $port $path
        return ;# NOTE: cannot tailcall here, because that will trigger [finally] and close the channel!
    }

    # Filters must be able to:
    #  [x] alter the request        (pass by reference)
    #  [x] provide a full response  (-code return)
    #  [ ] filter request body
    #  [ ] filter response
    try {
        filter::deproxify request preamble
        filter::basicauth request preamble
        filter::nokeepalive request preamble
    } on return {response opts} {
        puts -nonewline $chan $response
        return
    }

    log "Trying $verb $host:$port"
    set upchan [socket -async $host $port]  ;# FIXME: synchronous DNS blocks :(
    yieldto chan event $upchan writable [info coroutine]
    chan event $upchan writable ""
    set err [chan configure $upchan -error]
    if {$err ne ""} {
        log "Connect error: $err"
        # FIXME: smarter responses
        puts -nonewline $chan [dedent "
                    $httpver 502 Bad Gateway
                    Content-type: text/plain
                    Connection: close
                    
                    Error connecting to $host port $port:
                      $err
        "]
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

    # FIXME: handle persistent connections
    #   - need to intervene in the beginning of EVERY http request
    #   - which is kind of awful.  filter::nokeepalive will do?
    chan configure $chan   -buffering none -translation binary
    chan configure $upchan -buffering none -translation binary
    chan copy $chan $upchan -command [info coroutine]
    chan copy $upchan $chan -command [info coroutine]

    # wait for one chan to close:
    lassign [yieldm] nbytes err
    if {$err ne ""} {
        log "Error during transfer: $err"
        # which channel?  No eyed-deer
    }
    if {[chan eof $chan]} {     ;# this would be the wrong test if TCP supported tip#332 !
        log "Client abandoned keepalive"
        #close $upchan  ;# [finally] will do this for us
    } else {
        # wait until we're done sending to the client
        lassign [yieldm] nbytes err
        if {$err ne ""} {
            log "Error during transfer: $err"
        }
    }
    log "Done"
}

main {*}$argv
