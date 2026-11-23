-- Run once on a fresh schema after 06c_security_roles.sql. Demo data is fictional.
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

START TRANSACTION;
INSERT INTO cohort(id, code, label, intake_year) VALUES
  (1, '2025', '2025 届', 2025), (2, '2026', '2026 届', 2026);
INSERT INTO person(id, person_code, display_name) VALUES
  (1,'DEMO-MINISTER','示例部长'), (2,'DEMO-CHIEF','示例主编'),
  (3,'DEMO-SECOND','示例指导老师'), (4,'DEMO-THIRD','示例三审领导'),
  (5,'DEMO-WRITER','示例撰稿员'), (6,'DEMO-LAYOUT','示例排版员'),
  (7,'DEMO-PHOTO-A','示例摄影甲'), (8,'DEMO-PHOTO-B','示例摄影乙'),
  (9,'DEMO-VIDEO','示例剪辑员'), (10,'DEMO-FORMER','示例已退出成员'),
  (11,'DEMO-REJOINED','示例重新加入成员');
INSERT INTO membership_period(id, person_id, cohort_id, joined_at, left_at) VALUES
  (1,1,1,'2025-09-01',NULL), (2,2,1,'2025-09-01',NULL),
  (5,5,2,'2026-09-01',NULL), (6,6,2,'2026-09-01',NULL),
  (7,7,2,'2026-09-01',NULL), (8,8,2,'2026-09-01',NULL),
  (9,9,2,'2026-09-01',NULL), (10,10,1,'2025-09-01',NULL),
  (11,11,1,'2025-09-01','2026-06-01'), (12,11,2,'2026-09-01',NULL);
INSERT INTO membership_position(membership_id, position_code, starts_at, ends_at) VALUES
  (1,'MEMBER','2025-09-01','2026-09-01'), (1,'MINISTER','2026-09-01',NULL),
  (2,'MINISTER','2025-09-01','2026-09-01'), (2,'CHIEF','2026-09-01',NULL),
  (5,'MEMBER','2026-09-01',NULL), (6,'MEMBER','2026-09-01',NULL),
  (7,'MEMBER','2026-09-01',NULL), (8,'MEMBER','2026-09-01',NULL),
  (9,'MEMBER','2026-09-01',NULL), (10,'MEMBER','2025-09-01',NULL),
  (11,'MEMBER','2025-09-01','2026-06-01'), (12,'MEMBER','2026-09-01',NULL);

INSERT INTO skill(id,code,label) VALUES
  (1,'WRITING','新闻稿撰写'), (2,'XIUMI','秀米排版'), (3,'PHOTO','摄影'),
  (4,'VIDEO_SHOOT','视频拍摄'), (5,'VIDEO_EDIT','视频剪辑');
INSERT INTO person_skill(person_id,skill_id) VALUES
  (5,1),(6,2),(7,3),(7,4),(8,3),(9,4),(9,5),(10,3),(11,5),(1,5);

-- Structurally valid random demo verifiers. No demo plaintext or usable demo password exists.
INSERT INTO account(id, person_id, username, password_hash, enabled)
SELECT id, id, LOWER(person_code), CONCAT('$argon2id$v=19$m=65536,t=3,p=1$',
       REPLACE(TO_BASE64(RANDOM_BYTES(16)), '=', ''), '$',
       REPLACE(TO_BASE64(RANDOM_BYTES(32)), '=', '')), TRUE
FROM person;
INSERT INTO account_role(account_id, role_code) VALUES
  (1,'MANAGER'), (1,'MEMBER_ADMIN'), (2,'CHIEF_EDITOR'), (3,'EXTERNAL_REVIEWER'),
  (4,'EXTERNAL_REVIEWER'), (5,'CONTRIBUTOR'), (6,'CONTRIBUTOR'), (7,'CONTRIBUTOR'),
  (8,'CONTRIBUTOR'), (9,'CONTRIBUTOR'), (10,'CONTRIBUTOR'), (11,'CONTRIBUTOR');
INSERT INTO equipment(id,code,name,model,source,borrowed_at,due_back_at) VALUES
  (1,'CAM-DEMO-01','中心自有相机','示例型号 A','OWNED',NULL,NULL),
  (2,'CAM-DEMO-02','临时借入相机','示例型号 B','BORROWED',
     CURRENT_TIMESTAMP(6) - INTERVAL 1 DAY,CURRENT_TIMESTAMP(6) + INTERVAL 30 DAY);
COMMIT;

CALL sp_create_campaign(1,'SPORTS-2026','2026 年学院运动会宣传',
  '2026-10-24 08:00','2026-10-25 19:00',FALSE);
CALL sp_create_campaign(1,'VIDEO-REVIEW-LAB','视频送审演示活动',
  '2026-10-26 08:00','2026-10-27 19:00',FALSE);
SET @sports = (SELECT id FROM campaign WHERE code = 'SPORTS-2026');
SET @video_lab = (SELECT id FROM campaign WHERE code = 'VIDEO-REVIEW-LAB');

CALL sp_create_project(1,@sports,'ARTICLE','运动会微信公众号推文','ARTICLE','REVIEWED',TRUE);
CALL sp_create_project(1,@sports,'VIDEO','运动会花絮视频','VIDEO','REVIEWED',TRUE);
CALL sp_create_project(1,@sports,'PHOTO','运动会独立摄影','PHOTO','WORK_ONLY',TRUE);
CALL sp_create_project(1,@video_lab,'LEADER-VIDEO','部长亲自剪辑视频','VIDEO','REVIEWED',TRUE);
CALL sp_create_project(1,@video_lab,'TEAM-VIDEO','多名部员共同剪辑视频','VIDEO','REVIEWED',FALSE);
SET @article = (SELECT id FROM project WHERE campaign_id = @sports AND code = 'ARTICLE');
SET @video = (SELECT id FROM project WHERE campaign_id = @sports AND code = 'VIDEO');
SET @photo = (SELECT id FROM project WHERE campaign_id = @sports AND code = 'PHOTO');
SET @leader_video = (SELECT id FROM project WHERE campaign_id = @video_lab AND code = 'LEADER-VIDEO');
SET @team_video = (SELECT id FROM project WHERE campaign_id = @video_lab AND code = 'TEAM-VIDEO');

CALL sp_set_review_route(1,@article,'MINISTER',1);
CALL sp_set_review_route(1,@article,'CHIEF',2);
CALL sp_set_review_route(1,@article,'SECOND',3);
CALL sp_set_review_route(1,@article,'THIRD',4);
CALL sp_set_review_route(1,@video,'MINISTER',1);
CALL sp_set_review_route(1,@video,'CHIEF',2);
CALL sp_set_review_route(1,@video,'SECOND',3);
CALL sp_set_review_route(1,@video,'THIRD',4);
CALL sp_set_review_route(1,@leader_video,'CHIEF',2);
CALL sp_set_review_route(1,@leader_video,'SECOND',3);
CALL sp_set_review_route(1,@team_video,'MINISTER',1);
CALL sp_set_review_route(1,@team_video,'CHIEF',2);
CALL sp_set_review_route(1,@team_video,'SECOND',3);
CALL sp_set_review_route(1,@team_video,'THIRD',4);

CALL sp_create_work(1,@article,'WRITE','撰写新闻稿','WRITING',NULL,TRUE);
CALL sp_create_work(1,@article,'PHOTO','为推文拍摄并筛选照片','PHOTO',NULL,TRUE);
CALL sp_create_work(1,@article,'LAYOUT','秀米排版与草稿同步','LAYOUT',NULL,TRUE);
CALL sp_create_work(1,@article,'COPY','主编责编','COPY_EDIT',NULL,TRUE);
CALL sp_create_work(1,@video,'SHOOT','拍摄并筛选原始视频','VIDEO_SHOOT',NULL,TRUE);
CALL sp_create_work(1,@video,'EDIT','编辑运动会花絮','VIDEO_EDIT','MEMBER',TRUE);
CALL sp_create_work(1,@photo,'PHOTO','独立摄影与选片','PHOTO',NULL,TRUE);
CALL sp_create_work(1,@leader_video,'EDIT','部长独立剪辑','VIDEO_EDIT','MINISTER',TRUE);
CALL sp_create_work(1,@team_video,'EDIT','部员协作剪辑','VIDEO_EDIT','MEMBER',TRUE);

SET @w_write = (SELECT id FROM work_item WHERE project_id = @article AND code = 'WRITE');
SET @w_article_photo = (SELECT id FROM work_item WHERE project_id = @article AND code = 'PHOTO');
SET @w_layout = (SELECT id FROM work_item WHERE project_id = @article AND code = 'LAYOUT');
SET @w_copy = (SELECT id FROM work_item WHERE project_id = @article AND code = 'COPY');
SET @w_shoot = (SELECT id FROM work_item WHERE project_id = @video AND code = 'SHOOT');
SET @w_video_edit = (SELECT id FROM work_item WHERE project_id = @video AND code = 'EDIT');
SET @w_photo = (SELECT id FROM work_item WHERE project_id = @photo AND code = 'PHOTO');
SET @w_leader = (SELECT id FROM work_item WHERE project_id = @leader_video AND code = 'EDIT');
SET @w_team = (SELECT id FROM work_item WHERE project_id = @team_video AND code = 'EDIT');

CALL sp_assign_work(1,@w_write,7);
SET @first_writer = (SELECT id FROM work_assignment WHERE work_item_id = @w_write);
CALL sp_end_work_assignment(1,@first_writer);
CALL sp_assign_work(1,@w_write,5);
CALL sp_assign_work(1,@w_layout,6);
CALL sp_assign_work(1,@w_copy,2);
CALL sp_assign_work(1,@w_article_photo,7);
CALL sp_assign_work(1,@w_article_photo,8);
CALL sp_assign_work(1,@w_shoot,7);
CALL sp_assign_work(1,@w_shoot,9);
CALL sp_assign_work(1,@w_video_edit,9);
CALL sp_assign_work(1,@w_video_edit,12);
CALL sp_assign_work(1,@w_photo,7);
CALL sp_assign_work(1,@w_photo,10);
CALL sp_assign_work(1,@w_leader,1);
CALL sp_assign_work(1,@w_team,9);
CALL sp_assign_work(1,@w_team,12);

CALL sp_log_contribution(5,@w_write,5,'PRIMARY','2026-10-25 10:00',75,'完成新闻稿');
CALL sp_log_contribution(6,@w_layout,6,'PRIMARY','2026-10-25 11:00',55,'初次秀米排版');
CALL sp_log_contribution(2,@w_copy,2,'PRIMARY','2026-10-25 13:00',25,'核对新闻表述');
CALL sp_log_contribution(7,@w_article_photo,7,'PRIMARY','2026-10-24 11:00',100,'拍摄并筛选自己的照片');
CALL sp_log_contribution(8,@w_article_photo,8,'COLLABORATOR','2026-10-24 11:30',90,'筛选自己拍摄的照片');
CALL sp_log_contribution(7,@w_shoot,7,'PRIMARY','2026-10-24 12:00',50,'拍摄并筛选自己的视频');
CALL sp_log_contribution(9,@w_shoot,9,'COLLABORATOR','2026-10-24 13:00',80,'补拍与整理素材');
CALL sp_log_contribution(9,@w_video_edit,9,'PRIMARY','2026-10-25 14:00',60,'花絮粗剪');
CALL sp_log_contribution(11,@w_video_edit,12,'COLLABORATOR','2026-10-25 15:00',35,'协作剪辑');
CALL sp_log_contribution(7,@w_photo,7,'PRIMARY','2026-10-24 14:00',90,'独立摄影');
CALL sp_log_contribution(10,@w_photo,10,'COLLABORATOR','2026-10-24 15:00',45,'退出前参与摄影');
CALL sp_log_contribution(8,@w_photo,8,'COLLABORATOR','2026-10-24 15:30',30,'临时协作筛选');
CALL sp_log_contribution(1,@w_leader,1,'PRIMARY','2026-10-26 14:00',110,'部长独立完成成片');
CALL sp_log_contribution(9,@w_team,9,'PRIMARY','2026-10-26 14:00',120,'多人方式主剪');
CALL sp_log_contribution(11,@w_team,12,'COLLABORATOR','2026-10-26 15:00',75,'多人方式协作剪辑');

CALL sp_set_work_status(1,@w_write,0,'DONE');
CALL sp_set_work_status(1,@w_copy,0,'DONE');
CALL sp_set_work_status(1,@w_article_photo,0,'DONE');
CALL sp_set_work_status(1,@w_layout,0,'IN_PROGRESS');
CALL sp_set_work_status(1,@w_shoot,0,'DONE');
CALL sp_set_work_status(1,@w_video_edit,0,'IN_PROGRESS');
CALL sp_set_work_status(1,@w_photo,0,'DONE');
CALL sp_set_work_status(1,@w_leader,0,'DONE');
CALL sp_set_work_status(1,@w_team,0,'DONE');

SET @demo_now = CURRENT_TIMESTAMP(6);
CALL sp_reserve_camera(1,1,@w_article_photo,7,@demo_now - INTERVAL 10 MINUTE,@demo_now + INTERVAL 1 HOUR);
SET @owned_usage = (SELECT id FROM equipment_usage WHERE equipment_id = 1);
CALL sp_change_camera_usage(1,@owned_usage,'CHECKOUT');
CALL sp_change_camera_usage(1,@owned_usage,'RETURN');
CALL sp_reserve_camera(1,2,@w_shoot,9,@demo_now - INTERVAL 2 MINUTE,@demo_now + INTERVAL 2 HOUR);
SET @borrowed_usage = (SELECT id FROM equipment_usage WHERE equipment_id = 2);
CALL sp_change_camera_usage(1,@borrowed_usage,'CHECKOUT');

CALL sp_register_asset(5,@article,'WORD','新闻原稿','files/demo/sports-original.docx',NULL,@word);
CALL sp_register_asset(7,@article,'PHOTO','照片甲','files/demo/sports-photo-a.jpg',NULL,@photo_a);
CALL sp_register_asset(8,@article,'PHOTO','照片乙','files/demo/sports-photo-b.jpg',NULL,@photo_b);
CALL sp_register_asset(6,@article,'XIUMI_LINK','秀米预览一','https://example.invalid/xiumi/1',NULL,@xiumi_a);
CALL sp_register_asset(6,@article,'WECHAT_LINK','公众号预览一','https://example.invalid/wechat/1',NULL,@wechat_a);
CALL sp_register_asset(6,@article,'XIUMI_LINK','秀米预览二','https://example.invalid/xiumi/2',NULL,@xiumi_b);
CALL sp_register_asset(6,@article,'WECHAT_LINK','公众号预览二','https://example.invalid/wechat/2',NULL,@wechat_b);
CALL sp_register_asset(9,@video,'VIDEO_RAW','部员个人原始视频','files/demo/sports-video-raw.mp4',NULL,@raw_video);
CALL sp_register_asset(1,@leader_video,'VIDEO_FINAL','部长剪辑成片','files/demo/leader-final.mp4',NULL,@leader_asset);
CALL sp_register_asset(9,@team_video,'VIDEO_FINAL','协作剪辑成片','files/demo/team-final.mp4',NULL,@team_asset);

CALL sp_submit(6,@article,'XIUMI',JSON_ARRAY(@word,@photo_a,@photo_b,@xiumi_a),'提交秀米预览',@x1);
CALL sp_review_submission(1,@x1,'APPROVED','版式通过，可同步草稿箱。');
CALL sp_submit(6,@article,'WECHAT',JSON_ARRAY(@wechat_a),'草稿箱已同步',@wx1);
CALL sp_review_submission(2,@wx1,'RETURNED','请调整首图和图片说明。');
CALL sp_forward_rework(1,@wx1,'交原排版同学修改首图与图注。');
CALL sp_log_contribution(6,@w_layout,6,'PRIMARY','2026-10-25 16:00',25,'按主编意见修改排版');
CALL sp_submit(6,@article,'XIUMI',JSON_ARRAY(@word,@photo_a,@photo_b,@xiumi_b),'重新提交秀米',@x2);
CALL sp_review_submission(1,@x2,'APPROVED','修订版通过。');
CALL sp_submit(6,@article,'WECHAT',JSON_ARRAY(@wechat_b),'重新同步草稿箱',@wx2);
CALL sp_review_submission(2,@wx2,'APPROVED','内容和图注复核通过。');
CALL sp_review_submission(3,@wx2,'APPROVED','老师二审通过。');
CALL sp_set_work_status(1,@w_layout,1,'DONE');
CALL sp_publish(1,@wx2,'WECHAT','https://example.invalid/published/sports-2026');

CALL sp_submit(1,@leader_video,'VIDEO',JSON_ARRAY(@leader_asset),'部长作为实际剪辑人员提交',@leader_s);
CALL sp_review_submission(2,@leader_s,'APPROVED','主编通过部长剪辑版。');
CALL sp_set_review_route(1,@leader_video,'THIRD',4);
CALL sp_set_campaign_third_review(1,@video_lab,TRUE);
CALL sp_review_submission(3,@leader_s,'APPROVED','二审通过，交三审。');

CALL sp_submit(9,@team_video,'VIDEO',JSON_ARRAY(@team_asset),'部员共同剪辑提交',@team_s);
CALL sp_review_submission(1,@team_s,'APPROVED','部长初审通过协作剪辑版。');
CALL sp_review_submission(2,@team_s,'APPROVED','主编通过。');
CALL sp_review_submission(3,@team_s,'APPROVED','二审通过。');
CALL sp_review_submission(4,@team_s,'APPROVED','三审通过。');
CALL sp_publish(1,@team_s,'VIDEO','https://example.invalid/published/team-video');

CALL sp_exit_member(1,10);
