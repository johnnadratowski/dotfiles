#!/usr/bin/python
"""
This is a python module that can take a single word as an argument and it will
jumble that word to tell you all of the words the constituent letters can make
"""

# PyEnchant - https://pythonhosted.org/pyenchant/
import enchant

# Get the english dictionary we're going to use to check the words
EN_DICT = enchant.Dict("en_US")


def _get_words(current, rest):
    """
    Recursive function to find words by jumbling the letters of a word
    :param current: The word we're currently building
    :param rest: The rest of the word to process
    :return: A set of words that are found
    """
    # Use a set so we don't return duplicates
    found_words = set()

    for i, letter in enumerate(rest):

        if len(rest) > 1:
            # Pop out the current letter to pass the rest of the string
            new_rest = rest[:i] + rest[i+1:]
            found_words = found_words.union(_get_words(current + letter, new_rest))
        else:
            # If there isn't any more of the rest of the string to process,
            # test it against the dictionary to see if it's a word
            cur_word = current + letter
            print("Trying %s" % (cur_word))
            if EN_DICT.check(cur_word):
                print("Found %s!!!" % (cur_word))
                found_words.add(cur_word)
    return found_words


def get_words(jumble_word):
    """
    Gets the words that another can make by jumbling the letters
    :param word: The word we're jumbling
    :return: A set of words that are found
    """
    found_words = _get_words('', jumble_word)

    # Don't add the word we passed in!
    if jumble_word in found_words:
        found_words.remove(jumble_word)

    return found_words


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        word = sys.argv[1]
        words = get_words(word)
        if words:
            print("The following %s words were found in %s:" % (len(words), word))
            print("\n".join(words))
        else:
            print("No words were found in %s" % word)
    else:
        print("You must enter a word to try!")

