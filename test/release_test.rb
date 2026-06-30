# frozen_string_literal: true

require "test_helper"

class ReleaseTest < GhcaskTest::Case
  def test_concise_desc_keeps_short_descriptions
    assert_equal "Fast grep alternative", Ghcask.concise_desc("Fast grep alternative")
  end

  def test_concise_desc_keeps_short_text_whole
    text = "A tiny tool. It does a couple things." # <= 80, kept as-is, not reduced
    assert_equal text, Ghcask.concise_desc(text)
  end

  def test_concise_desc_reduces_to_first_sentence_when_over_80
    text = "A small fast tool for finding files on disk. " \
           "It also does a hundred other things that push this well past eighty characters."
    assert_equal "A small fast tool for finding files on disk", Ghcask.concise_desc(text)
  end

  def test_concise_desc_truncates_an_overlong_first_sentence
    long = "A high-performance desktop application for managing skills across multiple AI coding assistants. More."
    desc = Ghcask.concise_desc(long)
    assert_operator desc.length, :<=, 80
    refute_includes desc, "More" # only the first sentence
    assert desc.end_with?("…") # ellipsis marks the truncation
  end

  def test_concise_desc_handles_blank
    assert_equal "", Ghcask.concise_desc(nil)
    assert_equal "", Ghcask.concise_desc("   ")
  end
end
