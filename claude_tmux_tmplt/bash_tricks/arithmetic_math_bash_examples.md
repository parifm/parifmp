# Arithmetic and math

### Arithmetic command
```bash
(( x = 5, y = x * 2 ))
echo "$y"
```

### Increment
```bash
i=0
(( i++ ))
echo "$i"
```

### Compound assignment
```bash
n=10
(( n += 5 ))
echo "$n"
```

### Integer attribute
```bash
declare -i n=5
n+=3
echo "$n"
```

### Let
```bash
let "x = 3 + 4"
echo "$x"
```

### Ternary
```bash
n=7
echo $(( n % 2 == 0 ? 0 : 1 ))
```

### Division and modulo
```bash
echo $(( 17 / 5 )) $(( 17 % 5 ))
```

### Power
```bash
echo $(( 2 ** 10 ))
```

### Bitwise operators
```bash
echo $(( 5 & 3 )) $(( 5 | 3 )) $(( 5 ^ 3 )) $(( 1 << 4 ))
```

### Base conversion
```bash
echo $(( 16#ff )) $(( 2#1010 ))
```

### Hex and octal output
```bash
printf '%x %o\n' 255 8
```

### Float with awk
```bash
awk 'BEGIN { printf "%.2f\n", 10 / 3 }'
```

### Float with bc
```bash
echo "scale=3; 10 / 3" | bc
```

### Compare floats
```bash
awk -v a=1.5 -v b=2.5 'BEGIN { exit !(a < b) }' && echo less
```

### Sum with paste and bc
```bash
seq 5 | paste -sd+ - | bc
```

### Dice roll
```bash
echo $(( RANDOM % 6 + 1 ))
```

### Strong random number
```bash
echo "$SRANDOM"
```

### Zero-padded sequence
```bash
seq -w 1 5
```

### Formatted sequence
```bash
seq -f 'file%02g' 1 3
```
