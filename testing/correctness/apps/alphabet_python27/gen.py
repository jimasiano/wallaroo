from json import dumps
from random import choice, randrange
from string import lowercase
from struct import pack

# Construct input data list, and total votes as a dict
expected = {}
data = []
for x in xrange(1000):
    c = choice(lowercase)
    v = randrange(1,10000)
    data.append(pack(">IsI",5, c, v))
    expected[c] = expected.get(c, 0) + v

with open("input.msg", "wb") as fin:
    for v in data:
        fin.write(v)

with open("output.json", "wb") as fout:
    fout.write(dumps(expected))

print "{} inputs".format(len(data))
