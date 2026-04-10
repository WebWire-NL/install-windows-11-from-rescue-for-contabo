#!/bin/sh
curl -I -L -sS --max-time 30 'https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=9dd36437-8c53-4d86-80dc-29db90a63505&P1=1775719369&P2=601&P3=2&P4=fizoXRjVOXdAMg6a1PRgNIZMO8eeYkphp0nfA4VZxRwRnoitaEjdNb%2fu%2bEjZh9rti%2bdQv8d4XTZafuF1VBHfgn1tRGz8TTn%2foFRphlIU1rqnxpOMnbLGIqif%2bVMdnnXYLJkCx8bSKp3DevtHVE1rc%2fF5V3OXvXtZ0NWsUNW97OrTTXZQYyOFNpLtZoUKspcdJLktl4cu2axBhYFaWWh%2fYTCQy8IE%2fgFapNMea7KgfYIinsF338Xyy2iutI2bYa555qx1gzLXO30pV1dq7E%2bKlaPmh1YgCR7xQ%3d%3d' | head -n 20
printf 'EXIT:%s\n' $? 
