(ns find-words.core
  (:require [clojure.string :as str]
            [clojure.set :as set])
  (:gen-class))

(defn remove-idx
  "Function to remove an index from a string"
  [s idx]
  (str (subs s 0 idx) (subs s (inc idx))))

(defn try-word
  "Function that checks to see if a word is a dictionary word"
  [orig word]
  (if (and (not= orig word) (= word "oof")) ; FIXME: Add dictionary checking
    true
    false))

(defn jumble-word
  "Function to recursively find all the words a word can make up by jumbling the letters"
  ([] (#{}))
  ([rst] (jumble-word "" rst))
  ([cur rst]
    (flatten 
      (for [idx (range 0 (count rst)) :let [word (str cur (nth rst idx))]]
        (do
          ;(println word)
          (conj (jumble-word word (remove-idx rst idx)) word))))))

(defn jumble-word-async
  "Function to recursively find all the words a word can make up by jumbling the letters"
  ([] (#{}))
  ([rst] (jumble-word "" rst))
  ([cur rst]
    (flatten 
      (for [idx (range 0 (count rst)) :let [word (str cur (nth rst idx))]]
        (do
          ;(println word)
          (def words (agent #{}))
          (send words jumble-word-async word (remove-idx rst idx))
          (conj @words word))))))

(defn get-words
  "Function to find all the words a word can make up by jumbling the letters"
  [a]
  ;(set (filter #(try-word a %) (jumble-word a))))
  (set (filter #(try-word a %) (jumble-word-async a))))

(defn -main
  "Find all of the words rearranging characters of a given word"
  {:foo "bar"}
  [word]
  (println
    (let [words (get-words word)]
      (if (empty? words)
        "No words were found!"
        (format "The following words were found:\n%s" (str/join "\n" words))))))
