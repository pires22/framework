module sv;

struct StringView {
    char* data;
    usz length;
}

fn StringView create_view(String str, usz length) {
    return StringView { .data = (char*)str, .length = length };
}

fn StringView create_from_string_view(StringView* sv) {
    return StringView {
        .data = sv.data,
        .length = sv.length
    };
}

fn usz StringView.count_occurrences(&self, char delimiter) {
    usz i = 0;
    usz count = 0;
    while (i < self.length) {
        if (self.data[i] == delimiter) {
            count++;
        }
        i++;
    }
    return count;
}

fn StringView StringView.chop_by_delimiter(&self, char delimiter) {
    usz i = 0;
    while (i < self.length && self.data[i] != delimiter) {
        i++;
    }

    StringView result = { .data = self.data, .length = i };

    if (i < self.length) {
        self.data += i + 1;
        self.length -= i + 1;
    } else {
        self.length = 0;
    }

    return result;
}

fn String StringView.to_string(&self) {
	return (String)self.data[:self.length];
}