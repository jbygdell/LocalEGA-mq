#!/bin/bash

set -e
set -x

[[ -z "${CEGA_CONNECTION}" ]] && echo 'Environment CEGA_CONNECTION is empty' 1>&2 && exit 1
[[ -z "${MQ_USER}" ]] && echo 'Environment MQ_USER is empty' 1>&2 && exit 1
[[ -z "${MQ_PASSWORD_HASH}" ]] && echo 'Environment MQ_PASSWORD_HASH is empty' 1>&2 && exit 1

cat > /etc/rabbitmq/defs.json <<EOF
{"rabbit_version":"3.6.14",
 "users":[{"name":"${MQ_USER}","password_hash":"${MQ_PASSWORD_HASH}","hashing_algorithm":"rabbit_password_hashing_sha256","tags":"administrator"}],
 "vhosts":[{"name":"/"}],
 "permissions":[{"user":"guest","vhost":"/","configure":".*","write":".*","read":".*"}],
 "parameters":[],
 "global_parameters":[{"name":"cluster_name","value":"rabbit@localhost"}],
 "policies":[],
 "queues":[{"name":"files","vhost":"/","durable":true,"auto_delete":false,"arguments":{}},
	   {"name":"archived","vhost":"/","durable":true,"auto_delete":false,"arguments":{}},
	   {"name":"stableIDs","vhost":"/","durable":true,"auto_delete":false,"arguments":{}}],
 "exchanges":[{"name":"lega","vhost":"/","type":"topic","durable":true,"auto_delete":false,"internal":false,"arguments":{}},
              {"name":"cega","vhost":"/","type":"topic","durable":true,"auto_delete":false,"internal":false,"arguments":{}}],
 "bindings":[{"source":"lega", "vhost":"/", "destination":"archived",  "destination_type":"queue", "routing_key":"archived", "arguments":{}}]
}
EOF
chown rabbitmq:rabbitmq /etc/rabbitmq/defs.json
chmod 640 /etc/rabbitmq/defs.json

cat > /etc/rabbitmq/rabbitmq.config <<EOF
%% -*- mode: erlang -*-
%%
[{rabbit,[{loopback_users, [ ] },
          {tcp_listeners, [ 5672 ] },
          {ssl_listeners, [ ] },
          {hipe_compile, false },
	  {disk_free_limit, "1GB"}]},
 {rabbitmq_management, [ { listener, [ { port, 15672 }, { ssl, false }] },
                         { load_definitions, "/etc/rabbitmq/defs.json"} ]}
].
EOF
chown rabbitmq:rabbitmq /etc/rabbitmq/rabbitmq.config
chmod 640 /etc/rabbitmq/rabbitmq.config

# Problem of loading the plugins and definitions out-of-orders.
# Explanation: https://github.com/rabbitmq/rabbitmq-shovel/issues/13
# Therefore: we run the server, with some default confs
# and then we upload the cega-definitions through the HTTP API

# We cannot add those definitions to defs.json (loaded by the
# management plugin. See /etc/rabbitmq/rabbitmq.config)
# So we use curl afterwards, to upload the extras definitions
# See also https://pulse.mozilla.org/api/

# dest-exchange-key is not set for the shovel, so the key is re-used.

# For the moment, still using guest:guest
cat > /etc/rabbitmq/defs-cega.json <<EOF
{"parameters":[{"value": {"src-uri": "amqp://",
			  "src-exchange": "cega",
			  "src-exchange-key": "#",
			  "dest-uri": "${CEGA_CONNECTION}",
			  "dest-exchange": "localega.v1",
			  "add-forward-headers": false,
			  "ack-mode": "on-confirm",
			  "delete-after": "never"},
            	"vhost": "/",
		"component": "shovel",
		"name": "to-CEGA"},
	       {"value": {"src-uri": "amqp://",
			   "src-exchange": "lega",
			   "src-exchange-key": "completed",
			   "dest-uri": "amqp://",
			   "dest-exchange": "cega",
			   "dest-exchange-key": "files.completed",
			   "add-forward-headers": false,
			   "ack-mode": "on-confirm",
			   "delete-after": "never"},
		"vhost": "/",
		"component": "shovel",
		"name": "CEGA-completion"},
	       {"value":{"uri":"${CEGA_CONNECTION}",
			 "ack-mode":"on-confirm",
			 "trust-user-id":false,
			 "queue":"v1.files"},
		"vhost":"/",
		"component":"federation-upstream",
		"name":"CEGA-files"},
	       {"value":{"uri":"${CEGA_CONNECTION}",
			 "ack-mode":"on-confirm",
			 "trust-user-id":false,
			 "queue":"v1.stableIDs"},
		"vhost":"/",
		"component":"federation-upstream",
		"name":"CEGA-ids"}],
 "policies":[{"vhost":"/",
              "name":"CEGA-files",
              "pattern":"files",
              "apply-to":"queues",
              "definition":{"federation-upstream":"CEGA-files"},
              "priority":0},
             {"vhost":"/",
              "name":"CEGA-ids",
              "pattern":"stableIDs",
              "apply-to":"queues",
              "definition":{"federation-upstream":"CEGA-ids"},
              "priority":0}]
}
EOF
chown rabbitmq:rabbitmq /etc/rabbitmq/defs-cega.json
chmod 640 /etc/rabbitmq/defs-cega.json

# And...cue music
chown -R rabbitmq /var/lib/rabbitmq

{ # Spawn off
    sleep 5 # Small delay first

    # Wait until the server is ready (because we don't nave netcat we use wait on the pid)
    ROUND=30
    until rabbitmqctl wait /var/lib/rabbitmq/mnesia/rabbit@${HOSTNAME}.pid || ((ROUND<0))
    do
	sleep 1
	$((ROUND--))
    done
    ((ROUND<0)) && echo "Central EGA broker *_not_* started" 2>&1 && exit 1

    ROUND=30
    until rabbitmqadmin import /etc/rabbitmq/defs-cega.json || ((ROUND<0))
    do
 	sleep 1
 	$((ROUND--))
    done
    ((ROUND<0)) && echo "Central EGA connections *_not_* loaded" 2>&1 && exit 1
    echo "Central EGA connections loaded"
} &

exec "$@" # ie CMD rabbitmq-server
