-- Initial organization-independent RBAC data. Included in complete backups.
START TRANSACTION;
INSERT INTO `position`(code, label, hierarchy_rank) VALUES
  ('CHIEF','主编',3), ('MINISTER','部长',4), ('MEMBER','部员',5);
INSERT INTO system_role(code, label) VALUES
 ('MANAGER','业务主管'), ('CHIEF_EDITOR','主编业务权限'), ('EXTERNAL_REVIEWER','外部审核'),
 ('CONTRIBUTOR','成员业务权限'), ('MEMBER_ADMIN','人员管理权限');

INSERT INTO permission(code, label) VALUES
 ('MANAGE_PROJECT','管理活动、项目和工作'), ('ASSIGN_WORK','分配工作'),
 ('LOG_WORK','登记本人实际贡献'), ('LOG_WORK_FOR_OTHERS','为他人补登贡献'),
 ('REVIEW','审核指定项目'), ('SUBMIT','提交成果'), ('PUBLISH','发布成果'),
 ('REGISTER_ASSET','登记素材'), ('MANAGE_CAMERA','管理相机使用'), ('MANAGE_MEMBER','管理成员任期');

INSERT INTO role_permission(role_code, permission_code) VALUES
 ('MANAGER','MANAGE_PROJECT'), ('MANAGER','ASSIGN_WORK'), ('MANAGER','LOG_WORK'),
 ('MANAGER','LOG_WORK_FOR_OTHERS'), ('MANAGER','REVIEW'), ('MANAGER','SUBMIT'),
 ('MANAGER','PUBLISH'), ('MANAGER','REGISTER_ASSET'), ('MANAGER','MANAGE_CAMERA'),
 ('CHIEF_EDITOR','LOG_WORK'), ('CHIEF_EDITOR','REVIEW'), ('EXTERNAL_REVIEWER','REVIEW'),
 ('CONTRIBUTOR','LOG_WORK'), ('CONTRIBUTOR','SUBMIT'), ('CONTRIBUTOR','REGISTER_ASSET'),
 ('MEMBER_ADMIN','MANAGE_MEMBER');
COMMIT;
