-- ─── RPC 1: Paginated leaderboard with DENSE_RANK ─────────────
CREATE OR REPLACE FUNCTION get_leaderboard(p_limit INT, p_offset INT)
RETURNS TABLE (
  rank           BIGINT,
  user_id        UUID,
  username       TEXT,
  avatar_url     TEXT,
  total_xp       BIGINT,
  current_level  INT,
  current_streak INT
) LANGUAGE SQL STABLE SECURITY DEFINER AS $$
  SELECT
    DENSE_RANK() OVER (ORDER BY s.total_xp DESC) AS rank,
    s.user_id,
    COALESCE(p.username, 'Anonymous')             AS username,
    p.avatar_url,
    s.total_xp,
    s.current_level,
    COALESCE(str.current_streak, 0)               AS current_streak
  FROM user_stats s
  LEFT JOIN profiles     p   ON p.id      = s.user_id
  LEFT JOIN user_streaks str ON str.user_id = s.user_id
  ORDER BY s.total_xp DESC
  LIMIT  p_limit
  OFFSET p_offset;
$$;

-- ─── RPC 2: Single-user rank lookup ───────────────────────────
CREATE OR REPLACE FUNCTION get_user_rank(p_user_id UUID)
RETURNS BIGINT LANGUAGE SQL STABLE SECURITY DEFINER AS $$
  SELECT rank
  FROM (
    SELECT
      user_id,
      DENSE_RANK() OVER (ORDER BY total_xp DESC) AS rank
    FROM user_stats
  ) ranked
  WHERE user_id = p_user_id;
$$;


-- ─── RPC 3: Secure XP Award ────────────────────────────────────
CREATE OR REPLACE FUNCTION award_xp_secure(p_activity_type TEXT, p_metadata JSONB DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_base_xp INT;
  v_diff_weight NUMERIC;
  v_streak_mult NUMERIC;
  v_final_xp INT;
  v_current_streak INT;
  v_new_total_xp BIGINT;
  v_new_level INT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- 1. Get config
  SELECT base_xp, difficulty_weight INTO v_base_xp, v_diff_weight
  FROM xp_config WHERE activity_type = p_activity_type;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown activity type';
  END IF;

  -- 2. Get streak multiplier (default 1.0)
  SELECT current_streak, streak_multiplier INTO v_current_streak, v_streak_mult
  FROM user_streaks WHERE user_id = v_user_id;

  IF NOT FOUND THEN
    v_streak_mult := 1.0;
    v_current_streak := 0;
  END IF;

  -- 3. Compute XP
  v_final_xp := ROUND(v_base_xp * v_diff_weight * v_streak_mult);

  -- 4. Insert into ledger
  INSERT INTO xp_ledger (user_id, activity_type, base_xp, difficulty_weight, streak_multiplier, final_xp, metadata)
  VALUES (v_user_id, p_activity_type, v_base_xp, v_diff_weight, v_streak_mult, v_final_xp, p_metadata);

  -- 5. Fetch updated stats
  SELECT total_xp, current_level INTO v_new_total_xp, v_new_level
  FROM user_stats WHERE user_id = v_user_id;

  RETURN jsonb_build_object(
    'final_xp', v_final_xp,
    'base_xp', v_base_xp,
    'difficulty_weight', v_diff_weight,
    'streak_multiplier', v_streak_mult,
    'new_total_xp', v_new_total_xp,
    'new_level', v_new_level,
    'current_streak', v_current_streak
  );
END;
$$;

-- ─── RPC 4: Secure Game Score Save ─────────────────────────────
CREATE OR REPLACE FUNCTION save_game_score_secure(p_game_type TEXT, p_score INT, p_trash_collected INT DEFAULT 0)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF p_score > 1000000 THEN
    RAISE EXCEPTION 'Suspicious score rejected';
  END IF;

  INSERT INTO game_scores (user_id, game_type, score, trash_collected, created_at)
  VALUES (v_user_id, p_game_type, p_score, p_trash_collected, NOW());
END;
$$;

-- ─── RPC 5: Secure Badge Award ─────────────────────────────────
CREATE OR REPLACE FUNCTION award_badges_secure(p_badge_keys TEXT[])
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_key TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  FOREACH v_key IN ARRAY p_badge_keys
  LOOP
    INSERT INTO user_badges (user_id, badge_key)
    VALUES (v_user_id, v_key)
    ON CONFLICT DO NOTHING;
  END LOOP;
END;
$$;

-- ─── RPC 6: Community Post Interactions ────────────────────────
CREATE OR REPLACE FUNCTION increment_post_likes(p_post_id UUID, p_increment BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_increment THEN
    UPDATE community_posts SET likes = COALESCE(likes, 0) + 1 WHERE id = p_post_id;
  ELSE
    UPDATE community_posts SET likes = GREATEST(0, COALESCE(likes, 0) - 1) WHERE id = p_post_id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION increment_post_replies(p_post_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE community_posts SET replies = COALESCE(replies, 0) + 1 WHERE id = p_post_id;
END;
$$;
