#!/bin/bash

cf-remote spawn --platform debian-13 --role hub --name hub
cf-remote spawn --platform ubuntu-24 --role client --name ubuntu

sleep 60

cf-remote install --edition community --bootstrap hub --hub hub
cf-remote install --edition community --bootstrap hub --clients ubuntu
