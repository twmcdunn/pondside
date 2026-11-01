~lx[\pitches] = { |pcs, lo = 48, hi = 84| (lo..hi).select { |m| pcs.asArray.includes(m % 12) } };
