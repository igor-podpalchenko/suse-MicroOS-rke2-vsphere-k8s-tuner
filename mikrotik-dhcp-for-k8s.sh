# MikroTik DHCP Server Lease Script
# This script runs automatically when a lease is assigned/renewed
# Add this to: IP → DHCP Server → [Your Server] → Lease Script

# The idea behind - converts dynamic DHCP record (Mac to IP) to static DHCP record (no expiration). 
# Converted record stays active (renewed by VM at half of expiration time) until N days pass since last renewal.

# Available variables from DHCP server:
# leaseBound = 1 (lease assigned) or 0 (lease released)
# leaseServerName = DHCP server name
# leaseActMAC = client MAC address
# leaseActIP = assigned IP address
# lease-hostname = client hostname
# lease-options = DHCP options

:if ($leaseBound = 1) do={

    # Some RouterOS versions expose different variable names.
    # Prefer your ones, but fall back if they are empty.
    :local mac $leaseActMAC
    :if ([:len $mac] = 0) do={ :set mac $leaseMacAddress }

    :local ip $leaseActIP
    :if ([:len $ip] = 0) do={ :set ip $leaseAddress }

    :local srv $leaseServerName
    :if ([:len $srv] = 0) do={ :set srv "dhcp_192_60" }

    # Wait a moment for the dynamic lease to be created/updated
    :delay 1s

    # Find the dynamic lease that was just created
    :local ids [/ip dhcp-server lease find where mac-address=$mac and address=$ip and dynamic=yes]
    :if ([:len $ids] > 0) do={

        :local leaseID [:pick $ids 0]

        # Optional: read hostname (best-effort)
        :local hostname ""
        :do {
            :set hostname [/ip dhcp-server lease get $leaseID host-name]
        } on-error={}

        # Tag comment so cleanup scripts can target these later
        :local comment ("AUTO_STATIC " . $srv)

        # Convert to static in-place
        :do {
            /ip dhcp-server lease make-static $leaseID
            /ip dhcp-server lease set $leaseID comment=$comment

            :log info ("DHCP: made static " . $mac . " (" . $ip . ") host=" . $hostname . " server=" . $srv)
        } on-error={
            :log warning ("DHCP: make-static failed for " . $mac . " (" . $ip . ") server=" . $srv . " err=" . $message)
        }
    }
}

# Cleanup Script

:global ageSec do={
  :local s $1;
  :if ($s = "never") do={ :return 0; }

  :local total 0;

  :local p [:find $s "w"];
  :if ($p != -1) do={
    :set total ($total + ([:tonum [:pick $s 0 $p]] * 604800));
    :set s [:pick $s ($p+1) [:len $s]];
  }

  :set p [:find $s "d"];
  :if ($p != -1) do={
    :set total ($total + ([:tonum [:pick $s 0 $p]] * 86400));
    :set s [:pick $s ($p+1) [:len $s]];
  }

  :set p [:find $s "h"];
  :if ($p != -1) do={
    :set total ($total + ([:tonum [:pick $s 0 $p]] * 3600));
    :set s [:pick $s ($p+1) [:len $s]];
  }

  :set p [:find $s "m"];
  :if ($p != -1) do={
    :set total ($total + ([:tonum [:pick $s 0 $p]] * 60));
    :set s [:pick $s ($p+1) [:len $s]];
  }

  :set p [:find $s "s"];
  :if ($p != -1) do={
    :set total ($total + ([:tonum [:pick $s 0 $p]] * 1));
  }

  :return $total;
};

:local cutoff (3 * 86400);

:foreach id in=[/ip dhcp-server lease find where dynamic=no and comment="AUTO_STATIC dhcp_192_60"] do={
  :local status [/ip dhcp-server lease get $id status];
  :local ls [/ip dhcp-server lease get $id last-seen];
  :local age [$ageSec $ls];

  :if ($status != "bound" and $age > $cutoff) do={
    :local ip [/ip dhcp-server lease get $id address];
    :local mac [/ip dhcp-server lease get $id mac-address];
    :log info ("[dhcp60_cleanup] remove " . $ip . " " . $mac . " last-seen=" . $ls);
    /ip dhcp-server lease remove $id;
  }
}


# Script scheduler 
/system scheduler add name=dhcp60_cleanup interval=1d start-time=03:17:00 on-event=dhcp60_cleanup
